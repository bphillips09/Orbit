package com.bp.orbit

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import com.bp.orbit.headunit.HeadUnitAuxManager
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
  companion object {
    // Play the startup silence once per process
    @Volatile private var didPlayStartupSilence: Boolean = false
  }

  private val channelName = "com.bp.orbit/head_unit"
  private val executor = Executors.newCachedThreadPool()
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    playStartupSilenceOnce()
  }

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
          "exitAux" -> {
            val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 1500L)
            executor.execute {
              val res = try {
                HeadUnitAuxManager.exitAuxBlocking(applicationContext, timeoutMs)
              } catch (t: Throwable) {
                Result.failure<Boolean>(t)
              }
              mainHandler.post {
                res.fold(
                  onSuccess = { stopped -> result.success(stopped) },
                  onFailure = { err ->
                    result.error("EXIT_AUX_FAILED", err.message ?: "Failed to exit aux input", null)
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

  /**
   * Request transient media focus and abandon it afterwards
   * So head units register Orbit as audio-capable
   */
  private fun playStartupSilenceOnce() {
    if (didPlayStartupSilence) return
    didPlayStartupSilence = true

    executor.execute {
      val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return@execute
      val sampleRateHz = 48000
      val channelMask = AudioFormat.CHANNEL_OUT_STEREO
      val encoding = AudioFormat.ENCODING_PCM_16BIT

      val attrs = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

      val focusListener = AudioManager.OnAudioFocusChangeListener { /* No-op */ }
      var focusRequest: AudioFocusRequest? = null
      val focusGranted = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attrs)
            .setOnAudioFocusChangeListener(focusListener)
            .build()
          audioManager.requestAudioFocus(focusRequest!!) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
          @Suppress("DEPRECATION")
          audioManager.requestAudioFocus(
            focusListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
          ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
      } catch (_: Throwable) {
        false
      }

      var track: AudioTrack? = null
      try {
        val minBufferBytes = AudioTrack.getMinBufferSize(sampleRateHz, channelMask, encoding)
        if (minBufferBytes <= 0) return@execute

        val format = AudioFormat.Builder()
          .setEncoding(encoding)
          .setSampleRate(sampleRateHz)
          .setChannelMask(channelMask)
          .build()

        track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(minBufferBytes)
            .build()
        } else {
          @Suppress("DEPRECATION")
          AudioTrack(
            AudioManager.STREAM_MUSIC,
            sampleRateHz,
            channelMask,
            encoding,
            minBufferBytes,
            AudioTrack.MODE_STREAM
          )
        }

        val buffer = ByteArray(minBufferBytes) // All zeros, silence
        track.play()

        val endMs = SystemClock.elapsedRealtime() + 1000L
        while (SystemClock.elapsedRealtime() < endMs) {
          // Blocking write so we actually render audio frames for 1 second
          track.write(buffer, 0, buffer.size)
        }
      } catch (_: Throwable) {
        // Ignore failures
      } finally {
        try {
          track?.stop()
        } catch (_: Throwable) {}
        try {
          track?.release()
        } catch (_: Throwable) {}

        // Abandon focus if we requested it
        try {
          if (focusGranted) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && focusRequest != null) {
              audioManager.abandonAudioFocusRequest(focusRequest!!)
            } else {
              @Suppress("DEPRECATION")
              audioManager.abandonAudioFocus(focusListener)
            }
          }
        } catch (_: Throwable) {}
      }
    }
  }
}
