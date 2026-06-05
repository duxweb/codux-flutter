use futures_lite::StreamExt;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, TransportAddr,
    endpoint::{PathEvent, presets},
};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    ffi::{CStr, CString},
    net::SocketAddr,
    os::raw::c_char,
    str::FromStr,
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    runtime::Runtime,
    sync::mpsc,
    time::{Duration, timeout},
};

const ALPN: &[u8] = b"codux/remote/iroh/v1";

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static RUNTIME: Lazy<Runtime> = Lazy::new(|| Runtime::new().expect("create iroh runtime"));
static CLIENTS: Lazy<Mutex<HashMap<u64, ClientHandle>>> = Lazy::new(|| Mutex::new(HashMap::new()));

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConnectRequest {
    node_addr: RemoteIrohNodeAddr,
    #[serde(default)]
    relay_url: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemoteIrohNodeAddr {
    node_id: String,
    #[serde(default)]
    relay_url: Option<String>,
    #[serde(default)]
    direct_addresses: Vec<String>,
}

impl RemoteIrohNodeAddr {
    fn to_endpoint_addr(&self) -> Result<EndpointAddr, String> {
        let node_id =
            EndpointId::from_str(self.node_id.trim()).map_err(|error| error.to_string())?;
        let relay_url = self
            .relay_url
            .as_deref()
            .filter(|value| !value.trim().is_empty())
            .map(RelayUrl::from_str)
            .transpose()
            .map_err(|error| error.to_string())?;
        let mut addr = EndpointAddr::new(node_id);
        if let Some(relay_url) = relay_url {
            addr = addr.with_relay_url(relay_url);
        }
        for direct in self
            .direct_addresses
            .iter()
            .filter_map(|value| SocketAddr::from_str(value.trim()).ok())
        {
            addr = addr.with_ip_addr(direct);
        }
        Ok(addr)
    }
}

fn relay_mode_from_url(value: Option<&str>) -> Result<RelayMode, String> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(RelayMode::Default);
    };
    if value == "iroh://default" {
        return Ok(RelayMode::Default);
    }
    let relay_url = RelayUrl::from_str(value).map_err(|error| error.to_string())?;
    Ok(RelayMode::custom([relay_url]))
}

struct ClientHandle {
    endpoint: Option<Endpoint>,
    tx: mpsc::UnboundedSender<Vec<u8>>,
    events: std::sync::Arc<Mutex<VecDeque<String>>>,
    closed: bool,
}

#[unsafe(no_mangle)]
pub extern "C" fn codux_iroh_connect(config_json: *const c_char) -> u64 {
    let Some(config) = read_c_string(config_json) else {
        return 0;
    };
    let Ok(request) = serde_json::from_str::<ConnectRequest>(&config) else {
        return 0;
    };
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let events = std::sync::Arc::new(Mutex::new(VecDeque::new()));
    CLIENTS.lock().ok().map(|mut clients| {
        clients.insert(
            handle,
            ClientHandle {
                endpoint: None,
                tx,
                events: events.clone(),
                closed: false,
            },
        )
    });
    RUNTIME.spawn(run_client(handle, request, rx, events));
    handle
}

#[unsafe(no_mangle)]
pub extern "C" fn codux_iroh_send(handle: u64, envelope_json: *const c_char) -> bool {
    let Some(message) = read_c_string(envelope_json) else {
        return false;
    };
    let Some(client) = CLIENTS
        .lock()
        .ok()
        .and_then(|clients| clients.get(&handle).map(|client| client.tx.clone()))
    else {
        return false;
    };
    client.send(message.into_bytes()).is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn codux_iroh_add_node_addr(handle: u64, node_addr_json: *const c_char) -> bool {
    let Some(config) = read_c_string(node_addr_json) else {
        return false;
    };
    let Ok(node_addr) = serde_json::from_str::<RemoteIrohNodeAddr>(&config) else {
        return false;
    };
    let Ok(_node_addr) = node_addr.to_endpoint_addr() else {
        return false;
    };
    CLIENTS
        .lock()
        .ok()
        .and_then(|clients| clients.get(&handle).map(|_| true))
        .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub extern "C" fn codux_iroh_poll_event(handle: u64) -> *mut c_char {
    let event = CLIENTS.lock().ok().and_then(|mut clients| {
        let (event, should_remove) = {
            let client = clients.get(&handle)?;
            let event = client
                .events
                .lock()
                .ok()
                .and_then(|mut events| events.pop_front());
            let should_remove = event.is_none() && client.closed;
            (event, should_remove)
        };
        if should_remove {
            clients.remove(&handle);
        }
        event
    });
    match event {
        Some(event) => into_c_string(event),
        None => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn codux_iroh_close(handle: u64) {
    CLIENTS
        .lock()
        .ok()
        .map(|mut clients| clients.remove(&handle));
}

#[unsafe(no_mangle)]
pub extern "C" fn codux_iroh_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(value);
    }
}

async fn run_client(
    handle: u64,
    request: ConnectRequest,
    mut rx: mpsc::UnboundedReceiver<Vec<u8>>,
    events: std::sync::Arc<Mutex<VecDeque<String>>>,
) {
    emit(&events, json!({ "type": "state", "state": "connecting" }));
    let result = async {
        let relay_mode = relay_mode_from_url(request.relay_url.as_deref())?;
        let endpoint = Endpoint::builder(presets::N0)
            .relay_mode(relay_mode)
            .bind()
            .await
            .map_err(|error| error.to_string())?;
        if let Ok(mut clients) = CLIENTS.lock() {
            if let Some(client) = clients.get_mut(&handle) {
                client.endpoint = Some(endpoint.clone());
            }
        }
        let node_addr = request.node_addr.to_endpoint_addr()?;
        emit(
            &events,
            json!({
                "type": "state",
                "state": "resolving",
                "nodeId": request.node_addr.node_id,
                "relayUrl": request.node_addr.relay_url,
                "directAddressCount": request.node_addr.direct_addresses.len(),
            }),
        );
        let connection = timeout(Duration::from_secs(8), endpoint.connect(node_addr, ALPN))
            .await
            .map_err(|_| "Iroh connect timed out".to_string())?
            .map_err(|error| error.to_string())?;
        emit(&events, json!({ "type": "state", "state": "transport" }));
        let connection_for_path = connection.clone();
        let events_for_path = events.clone();
        let conn_type_task = tokio::spawn(async move {
            emit_connection_paths(&events_for_path, &connection_for_path);
            let mut events = connection_for_path.path_events();
            while let Some(event) = events.next().await {
                match event {
                    PathEvent::Selected { remote_addr, .. } => {
                        emit_transport_addr(&events_for_path, &remote_addr);
                    }
                    PathEvent::Lagged { .. } => {
                        emit_connection_paths(&events_for_path, &connection_for_path);
                    }
                    _ => {}
                }
            }
        });
        emit(&events, json!({ "type": "state", "state": "connected" }));
        let (mut send, mut recv) = connection
            .open_bi()
            .await
            .map_err(|error| error.to_string())?;
        loop {
            tokio::select! {
                inbound = read_frame(&mut recv) => {
                    let data = inbound?;
                    if let Ok(envelope) = serde_json::from_slice::<Value>(&data) {
                        emit(&events, json!({ "type": "envelope", "envelope": envelope }));
                    }
                }
                outbound = rx.recv() => {
                    let Some(data) = outbound else {
                        break;
                    };
                    write_frame(&mut send, &data).await?;
                }
            }
        }
        let _ = send.finish();
        conn_type_task.abort();
        endpoint.close().await;
        Ok::<(), String>(())
    }
    .await;
    match result {
        Ok(()) => emit(&events, json!({ "type": "state", "state": "closed" })),
        Err(error) => emit(
            &events,
            json!({ "type": "state", "state": "failed", "error": error }),
        ),
    }
    if let Ok(mut clients) = CLIENTS.lock() {
        if let Some(client) = clients.get_mut(&handle) {
            client.closed = true;
        }
    }
}

async fn write_frame<W>(writer: &mut W, data: &[u8]) -> Result<(), String>
where
    W: AsyncWriteExt + Unpin,
{
    let len = u32::try_from(data.len()).map_err(|_| "Remote message is too large".to_string())?;
    writer
        .write_all(&len.to_be_bytes())
        .await
        .map_err(|error| error.to_string())?;
    writer
        .write_all(data)
        .await
        .map_err(|error| error.to_string())
}

async fn read_frame<R>(reader: &mut R) -> Result<Vec<u8>, String>
where
    R: AsyncReadExt + Unpin,
{
    let mut header = [0_u8; 4];
    reader
        .read_exact(&mut header)
        .await
        .map_err(|error| error.to_string())?;
    let len = u32::from_be_bytes(header) as usize;
    if len > 8 * 1024 * 1024 {
        return Err("Remote message is too large".to_string());
    }
    let mut data = vec![0_u8; len];
    reader
        .read_exact(&mut data)
        .await
        .map_err(|error| error.to_string())?;
    Ok(data)
}

fn emit(events: &Mutex<VecDeque<String>>, event: Value) {
    if let Ok(mut events) = events.lock() {
        events.push_back(event.to_string());
        while events.len() > 256 {
            events.pop_front();
        }
    }
}

fn emit_connection_paths(
    events: &Mutex<VecDeque<String>>,
    connection: &iroh::endpoint::Connection,
) {
    let paths = connection.paths();
    if let Some(path) = paths.iter().find(|path| path.is_selected()) {
        emit_transport_addr(events, path.remote_addr());
    }
}

fn emit_transport_addr(events: &Mutex<VecDeque<String>>, addr: &TransportAddr) {
    let (path, detail) = match addr {
        TransportAddr::Relay(url) => ("relay", url.to_string()),
        TransportAddr::Ip(addr) => ("direct", addr.to_string()),
        TransportAddr::Custom(addr) => ("mixed", addr.to_string()),
        _ => ("mixed", String::new()),
    };
    emit(
        events,
        json!({
            "type": "state",
            "state": "path",
            "path": path,
            "detail": detail,
        }),
    );
}

fn read_c_string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value).to_str().ok().map(str::to_string) }
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}
