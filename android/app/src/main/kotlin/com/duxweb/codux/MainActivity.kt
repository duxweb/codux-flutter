package com.duxweb.codux

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var pendingVoiceResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listen" -> startVoiceRecognition(
                        localeTag = call.argument<String>("locale"),
                        result = result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun startVoiceRecognition(localeTag: String?, result: MethodChannel.Result) {
        if (pendingVoiceResult != null) {
            result.error("busy", "Voice recognition is already running.", null)
            return
        }

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            val language = localeTag?.takeIf { it.isNotBlank() } ?: Locale.getDefault().toLanguageTag()
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
        }

        pendingVoiceResult = result
        try {
            startActivityForResult(intent, VOICE_REQUEST_CODE)
        } catch (error: ActivityNotFoundException) {
            pendingVoiceResult = null
            result.error("unavailable", "No speech recognizer is available on this device.", null)
        }
    }

    @Deprecated("Deprecated in Android API but still supported by FlutterActivity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VOICE_REQUEST_CODE) {
            val result = pendingVoiceResult ?: return
            pendingVoiceResult = null
            if (resultCode == Activity.RESULT_OK) {
                val matches = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                result.success(matches?.firstOrNull().orEmpty())
            } else {
                result.success("")
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        private const val VOICE_CHANNEL = "codux_mobile/voice"
        private const val VOICE_REQUEST_CODE = 4104
    }
}
