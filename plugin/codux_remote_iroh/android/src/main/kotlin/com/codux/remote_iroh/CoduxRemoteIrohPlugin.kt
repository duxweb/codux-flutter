package com.codux.remote_iroh

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin

class CoduxRemoteIrohPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        System.loadLibrary("codux_remote_iroh_bridge")
        initializeNativeContext(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit

    private external fun initializeNativeContext(context: Context)
}
