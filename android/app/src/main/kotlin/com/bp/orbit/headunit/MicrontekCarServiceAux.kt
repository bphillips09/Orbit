package com.bp.orbit.headunit

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.IBinder
import android.os.Parcel

/**
 * Microntek / MTC* (PX5/PX6/Qualcomm) aux-in switching via the "CarService" binder
 */
object MicrontekCarServiceAux : HeadUnitAuxBackend {
  override val id: String = "microntek_carservice"

  private const val SERVICE_NAME = "carservice"
  private const val TOKEN = "android.microntek.ICarService"

  private const val ACTION_CAR_MANAGER_EVENT = "com.microntek.CarManager.event"
  private const val EXTRA_PARAMETER = "parameter"

  private const val TX_GET_STRING_STATE = 11
  private const val TX_SET_PARAMETERS = 17

  private const val KEY_AV_CHANNEL = "av_channel"
  private const val CHANNEL_LINE = "line"
  private const val CHANNEL_SYS = "sys"
  override fun isSupported(context: Context): Boolean {
    val pm = context.packageManager
    val hasPkg = try {
      @Suppress("DEPRECATION")
      pm.getPackageInfo("android.microntek.service", 0)
      true
    } catch (_: Throwable) {
      try {
        @Suppress("DEPRECATION")
        pm.getPackageInfo("com.microntek.avin", 0)
        true
      } catch (_: Throwable) {
        false
      }
    }
    return hasPkg
  }

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return runCatching {
      val appContext = context.applicationContext
      val enter = "av_channel_enter=$CHANNEL_LINE"

      // Prefer broadcast path
      sendCarManagerEvent(appContext, enter)

      // Give ROM a moment to update state
      try { Thread.sleep(150L) } catch (_: Throwable) {}

      // If we can read state and it isn't "line", try binder fallback
      val before = readAvChannel(appContext)
      if (before.isSuccess && before.getOrNull() != CHANNEL_LINE) {
        val car = getCarServiceBinder()
        if (car != null) {
          val rc = setParameters(car, enter).getOrThrow()
          if (rc < 0) error("carservice setParameters failed (rc=$rc, par=$enter)")
          try { Thread.sleep(150L) } catch (_: Throwable) {}
        }
      }

      // Read back channel and report whether aux is active
      val after = readAvChannel(appContext)
      val ch = after.getOrNull()
      if (ch == CHANNEL_LINE) {
        true
      } else {
        false
      }
    }
  }

  override fun exitAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return runCatching {
      val appContext = context.applicationContext
      val exit = "av_channel_exit=$CHANNEL_LINE"

      // If we're not on line-in, nothing to do
      val before = readAvChannel(appContext).getOrNull()
      if (before != CHANNEL_LINE) return@runCatching true

      // Prefer broadcast path
      sendCarManagerEvent(appContext, exit)

      val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(250L)
      while (System.currentTimeMillis() < deadline) {
        val ch = readAvChannel(appContext).getOrNull()
        if (ch != null && ch != CHANNEL_LINE) return@runCatching true
        try { Thread.sleep(60L) } catch (_: Throwable) {}
      }

      // Binder fallback
      val car = getCarServiceBinder()
      if (car != null) {
        val rc = setParameters(car, exit).getOrThrow()
        if (rc < 0) error("carservice setParameters failed (rc=$rc, par=$exit)")
      }

      try { Thread.sleep(150L) } catch (_: Throwable) {}
      readAvChannel(appContext).getOrNull() != CHANNEL_LINE
    }
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return runCatching {
      val ch = readAvChannel(context.applicationContext).getOrThrow()
      ch == CHANNEL_LINE
    }
  }

  private fun sendCarManagerEvent(context: Context, parameter: String) {
    try {
      context.sendBroadcast(Intent(ACTION_CAR_MANAGER_EVENT).putExtra(EXTRA_PARAMETER, parameter))
    } catch (_: Throwable) {
      // Ignore
    }
  }

  /**
   * Determine active input
   */
  private fun readAvChannel(context: Context): Result<String> {
    try {
      val car = getCarServiceBinder()
      if (car != null) {
        val viaBinder = getStringState(car, KEY_AV_CHANNEL)
        if (viaBinder.isSuccess) return viaBinder
      }
    } catch (_: Throwable) {
      // Ignore and try AudioManager
    }

    return runCatching {
      val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        ?: error("AudioManager unavailable")

      // Common patterns on Android: returns "key=value" pairs, sometimes ";" separated.
      val raw = listOf(
        am.getParameters(KEY_AV_CHANNEL),
        am.getParameters("${KEY_AV_CHANNEL}_enter"),
        am.getParameters("av_channel_enter"),
      ).firstOrNull { !it.isNullOrBlank() } ?: error("No av_channel parameters available")

      val v = parseParameterValue(raw, KEY_AV_CHANNEL)
        ?: parseParameterValue(raw, "av_channel_enter")
        ?: raw.trim()

      // Normalize
      when {
        v.contains(CHANNEL_LINE, ignoreCase = true) -> CHANNEL_LINE
        v.contains(CHANNEL_SYS, ignoreCase = true) -> CHANNEL_SYS
        else -> v
      }
    }
  }

  private fun parseParameterValue(raw: String, key: String): String? {
    val parts = raw.split(';')
    for (p in parts) {
      val idx = p.indexOf('=')
      if (idx <= 0) continue
      val k = p.substring(0, idx).trim()
      if (k == key) return p.substring(idx + 1).trim()
    }
    return null
  }

  private fun getCarServiceBinder(): IBinder? {
    // Reflection
    val sm = Class.forName("android.os.ServiceManager")
    val m = sm.getMethod("getService", String::class.java)
    return (m.invoke(null, SERVICE_NAME) as? IBinder)
  }

  private fun setParameters(car: IBinder, par: String): Result<Int> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN)
      data.writeString(par)
      car.transact(TX_SET_PARAMETERS, data, reply, 0)
      reply.readException()
      Result.success(reply.readInt())
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  private fun getStringState(car: IBinder, key: String): Result<String> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN)
      data.writeString(key)
      car.transact(TX_GET_STRING_STATE, data, reply, 0)
      reply.readException()
      val s = reply.readString()
      if (s != null) Result.success(s) else Result.failure(NullPointerException("getStringState($key) returned null"))
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }
}

