package com.example.kazumi

import android.app.PendingIntent
import android.content.Intent
import android.content.IntentFilter
import android.content.BroadcastReceiver
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.app.RemoteAction
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.net.Uri
import android.app.PictureInPictureParams
import android.view.Display
import android.graphics.drawable.Icon
import android.util.Log
import android.util.Rational
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity: AudioServiceActivity() {
    private val TAG = "KazumiMainActivity"
    private val CHANNEL = "com.predidit.kazumi/intent"
    private val STORAGE_CHANNEL = "com.predidit.kazumi/storage"
    private val PIP_CHANNEL = "com.predidit.kazumi/pip"
    private var intentChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null

    private var pipIsPlaying = false
    private var pipDanmakuEnabled = false
    private var pipActionReceiverRegistered = false
    private var autoEnterPipOnHomeGesture = false
    private var pipInPlayerPage = false
    private var pipAspectWidth = 16
    private var pipAspectHeight = 9
    private var androidFullscreen = false

    private val actionPipPlayPause = "com.predidit.kazumi.pip.PLAY_PAUSE"
    private val actionPipForward = "com.predidit.kazumi.pip.FORWARD"
    private val actionPipToggleDanmaku = "com.predidit.kazumi.pip.TOGGLE_DANMAKU"

    override fun getRenderMode(): RenderMode {
        return RenderMode.texture
    }

    private val pipActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            val action = intent?.action ?: return
            when (action) {
                actionPipPlayPause -> notifyFlutterPipAction("play_pause")
                actionPipForward -> notifyFlutterPipAction("forward")
                actionPipToggleDanmaku -> notifyFlutterPipAction("toggle_danmaku")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerPipActionReceiverIfNeeded()
    }

    override fun onDestroy() {
        unregisterPipActionReceiverIfNeeded()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && androidFullscreen) {
            applyAndroidFullscreen()
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        intentChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        intentChannel?.setMethodCallHandler { call, result ->
            if (call.method == "openWithMime") {
                val url = call.argument<String>("url")
                val mimeType = call.argument<String>("mimeType")
                if (url != null && mimeType != null) {
                    openWithMime(url, mimeType)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "URL and MIME type required", null)
                }
            } else if (call.method == "checkIfInMultiWindowMode") {
                val isInMultiWindow = checkIfInMultiWindowMode()
                result.success(isInMultiWindow)
            } else if (call.method == "getAndroidSdkVersion") {
                val sdkVersion = getAndroidSdkVersion()
                result.success(sdkVersion)
            } else if (call.method == "getAndroidHdrPeakBrightness") {
                result.success(getAndroidHdrPeakBrightness())
            } else if (call.method == "getAndroidHdrDisplayCapabilities") {
                result.success(getAndroidHdrDisplayCapabilities())
            } else if (call.method == "setAndroidHdrMode") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                result.success(setAndroidHdrMode(enabled))
            } else if (call.method == "enterFullscreen") {
                enterAndroidFullscreen()
                result.success(null)
            } else if (call.method == "exitFullscreen") {
                exitAndroidFullscreen()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getAvailableStorage") {
                val path = call.argument<String>("path") ?: filesDir.absolutePath
                val availableBytes = getAvailableStorage(path)
                result.success(availableBytes)
            } else {
                result.notImplemented()
            }
        }

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
        pipChannel?.setMethodCallHandler { call, result ->
            if (call.method == "isPictureInPictureSupported") {
                result.success(isPictureInPictureSupported())
            } else if (call.method == "enterPictureInPictureMode") {
                pipAspectWidth = call.argument<Int>("width") ?: pipAspectWidth
                pipAspectHeight = call.argument<Int>("height") ?: pipAspectHeight
                val entered = enterPictureInPicture()
                result.success(entered)
            } else if (call.method == "updatePictureInPictureActions") {
                val playing = call.argument<Boolean>("playing") ?: false
                val danmakuEnabled = call.argument<Boolean>("danmakuEnabled") ?: false
                pipAspectWidth = call.argument<Int>("width") ?: pipAspectWidth
                pipAspectHeight = call.argument<Int>("height") ?: pipAspectHeight
                updatePictureInPictureActions(playing, danmakuEnabled)
                result.success(true)
            } else if (call.method == "setAndroidAutoEnterPIPEnabled") {
                autoEnterPipOnHomeGesture = call.argument<Boolean>("enabled") ?: false
                refreshPictureInPictureParamsIfNeeded()
                result.success(true)
            } else if (call.method == "setAndroidPIPInPlayerPage") {
                pipInPlayerPage = call.argument<Boolean>("inPlayerPage") ?: false
                refreshPictureInPictureParamsIfNeeded()
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun openWithMime(url: String, mimeType: String) {
        val intent = Intent()
        intent.action = Intent.ACTION_VIEW
        intent.setDataAndType(Uri.parse(url), mimeType)
        startActivity(intent)
    }

    private fun checkIfInMultiWindowMode(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            this.isInMultiWindowMode 
        } else {
            false 
        }
    }

    private fun getAndroidSdkVersion(): Int {
        return Build.VERSION.SDK_INT
    }

    private fun getAndroidHdrPeakBrightness(): Double? {
        return getAndroidHdrDisplayCapabilities()?.get("maxLuminance") as? Double
    }

    private fun getAndroidHdrDisplayCapabilities(): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return null
        }
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        } ?: return null
        val hdrCapabilities = display.hdrCapabilities ?: return null
        val supportedHdrTypes = hdrCapabilities.supportedHdrTypes
        if (supportedHdrTypes.isEmpty()) {
            return null
        }
        val desiredMaxLuminance = hdrCapabilities.desiredMaxLuminance
        val desiredMaxAverageLuminance = hdrCapabilities.desiredMaxAverageLuminance
        val desiredMinLuminance = hdrCapabilities.desiredMinLuminance
        val result = mutableMapOf<String, Any>(
            "supportedHdrTypes" to supportedHdrTypes.toList()
        )
        if (desiredMaxLuminance.isFinite() && desiredMaxLuminance > 0f) {
            result["maxLuminance"] = desiredMaxLuminance.toDouble()
        }
        if (desiredMaxAverageLuminance.isFinite() && desiredMaxAverageLuminance > 0f) {
            result["maxAverageLuminance"] = desiredMaxAverageLuminance.toDouble()
        }
        if (desiredMinLuminance.isFinite() && desiredMinLuminance >= 0f) {
            result["minLuminance"] = desiredMinLuminance.toDouble()
        }
        return result
    }

    private fun setAndroidHdrMode(enabled: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        return try {
            window.colorMode = if (enabled) {
                ActivityInfo.COLOR_MODE_HDR
            } else {
                ActivityInfo.COLOR_MODE_DEFAULT
            }
            Log.i(TAG, "Android HDR window mode requested: enabled=$enabled colorMode=${window.colorMode}")
            window.colorMode == if (enabled) {
                ActivityInfo.COLOR_MODE_HDR
            } else {
                ActivityInfo.COLOR_MODE_DEFAULT
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to set Android HDR window mode", e)
            false
        }
    }

    private fun enterAndroidFullscreen() {
        androidFullscreen = true
        applyAndroidFullscreen()
    }

    private fun applyAndroidFullscreen() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    private fun exitAndroidFullscreen() {
        androidFullscreen = false
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView)
            .show(WindowInsetsCompat.Type.systemBars())
    }

    private fun isPictureInPictureSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        return packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun enterPictureInPicture(): Boolean {
        if (!isPictureInPictureSupported()) {
            return false
        }
        if (isInPictureInPictureMode) {
            return true
        }
        return enterPictureInPictureMode(buildPictureInPictureParams())
    }

    private fun updatePictureInPictureActions(
        playing: Boolean,
        danmakuEnabled: Boolean
    ) {
        if (!isPictureInPictureSupported()) {
            return
        }
        pipIsPlaying = playing
        pipDanmakuEnabled = danmakuEnabled
        refreshPictureInPictureParamsIfNeeded()
    }

    private fun buildPictureInPictureParams(): PictureInPictureParams {
        val actions = buildPipActions()
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(pipAspectWidth, pipAspectHeight))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnterPipOnHomeGesture && pipInPlayerPage)
            builder.setSeamlessResizeEnabled(false)
        }
        if (actions.isNotEmpty()) {
            builder.setActions(actions)
        }
        return builder.build()
    }

    private fun refreshPictureInPictureParamsIfNeeded() {
        if (!isPictureInPictureSupported()) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setPictureInPictureParams(buildPictureInPictureParams())
        }
    }

    private fun buildPipActions(): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return emptyList()
        }

        val allActions = mutableListOf<RemoteAction>(
            createPipAction(
                action = actionPipToggleDanmaku,
                requestCode = 1003,
                iconRes = if (pipDanmakuEnabled) R.drawable.ic_pip_danmaku_on else R.drawable.ic_pip_danmaku_off,
                title = if (pipDanmakuEnabled) "Danmaku On" else "Danmaku Off",
                description = if (pipDanmakuEnabled) "Turn off danmaku" else "Turn on danmaku",
                enabled = true
            ),
            createPipAction(
                action = actionPipPlayPause,
                requestCode = 1001,
                iconRes = if (pipIsPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                title = if (pipIsPlaying) "Pause" else "Play",
                description = if (pipIsPlaying) "Pause playback" else "Play playback",
                enabled = true
            ),
            createPipAction(
                action = actionPipForward,
                requestCode = 1002,
                iconRes = R.drawable.ic_pip_forward_80,
                title = "Forward",
                description = "Forward by custom seconds",
                enabled = true
            )
        )

        val maxActions = maxNumPictureInPictureActions
        if (allActions.size > maxActions) {
            allActions.subList(maxActions, allActions.size).clear()
        }
        return allActions
    }

    private fun createPipAction(
        action: String,
        requestCode: Int,
        iconRes: Int,
        title: String,
        description: String,
        enabled: Boolean
    ): RemoteAction {
        val intent = Intent(action).setPackage(packageName)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return RemoteAction(
            Icon.createWithResource(this, iconRes),
            title,
            description,
            pendingIntent
        ).apply {
            setEnabled(enabled)
        }
    }

    private fun notifyFlutterPipAction(action: String) {
        pipChannel?.invokeMethod("onAction", mapOf("action" to action))
    }

    private fun registerPipActionReceiverIfNeeded() {
        if (pipActionReceiverRegistered || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val filter = IntentFilter().apply {
            addAction(actionPipPlayPause)
            addAction(actionPipForward)
            addAction(actionPipToggleDanmaku)
        }
        ContextCompat.registerReceiver(
            this,
            pipActionReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        pipActionReceiverRegistered = true
    }

    private fun unregisterPipActionReceiverIfNeeded() {
        if (!pipActionReceiverRegistered) {
            return
        }
        unregisterReceiver(pipActionReceiver)
        pipActionReceiverRegistered = false
    }

    private fun getAvailableStorage(path: String): Long {
        return try {
            val stat = StatFs(path)
            stat.availableBlocksLong * stat.blockSizeLong
        } catch (e: Exception) {
            -1L
        }
    }
}
