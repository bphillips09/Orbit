package com.bp.orbit

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import com.bp.orbit.headunit.HeadUnitAuxManager
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
  private val channelName = "com.bp.orbit/head_unit"
  private val executor = Executors.newCachedThreadPool()
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "isSupported" -> {
            executor.execute {
              val supported = try {
                HeadUnitAuxManager.isSupported(applicationContext)
              } catch (t: Throwable) {
                false
              }
              mainHandler.post { result.success(supported) }
            }
          }
          "getBackend" -> {
            executor.execute {
              val backend = try {
                HeadUnitAuxManager.backendIdOrNull(applicationContext)
              } catch (t: Throwable) {
                null
              }
              mainHandler.post { result.success(backend) }
            }
          }
          "switchToAux" -> {
            val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 1500L)
            executor.execute {
              val res = try {
                HeadUnitAuxManager.switchToAuxBlocking(applicationContext, timeoutMs)
              } catch (t: Throwable) {
                Result.failure<Boolean>(t)
              }
              mainHandler.post {
                res.fold(
                  onSuccess = { opened -> result.success(opened) },
                  onFailure = { err ->
                    result.error("SWITCH_TO_AUX_FAILED", err.message ?: "Failed to switch to aux input", null)
                  }
                )
              }
            }
          }
          "isCurrentInputAux" -> {
            val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 1500L)
            executor.execute {
              val res = try {
                HeadUnitAuxManager.isCurrentInputAuxBlocking(applicationContext, timeoutMs)
              } catch (t: Throwable) {
                Result.failure<Boolean>(t)
              }
              mainHandler.post {
                res.fold(
                  onSuccess = { isAux -> result.success(isAux) },
                  onFailure = { err ->
                    result.error("IS_CURRENT_INPUT_AUX_FAILED", err.message ?: "Failed to query current input", null)
                  }
                )
              }
            }
          }
          else -> result.notImplemented()
        }
      }
  }
}
