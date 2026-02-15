package com.bp.orbit.headunit

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.IBinder
import android.os.IInterface
import android.os.Parcel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * JanCar / Autochips AUX-in switching.
 *
 * Observed OEM path:
 * - Start exported service `com.autochips.backcarapp.AvInService` with action `open_av_in`
 *   (which internally calls into `com.jancar.services.avin.AVInService` and opens AV id 21 == AUX).
 *
 * We also implement a fallback direct binder call to `com.jancar.services.action.avin`:
 * - IAVIn.open(21, callback, packageName)
 * - IAVIn.isOpen(21)
 */
object JancarAutochipsAux : HeadUnitAuxBackend {
  override val id: String = "jancar_autochips"

  private const val PKG_AUTOCHIPS_BACKCAR = "com.autochips.backcarapp"
  private const val CLS_AUTOCHIPS_AVIN_SERVICE = "com.autochips.backcarapp.AvInService"

  private const val ACTION_OPEN_AV_IN = "open_av_in"
  private const val ACTION_CLOSE_AV_IN = "close_av_in"
  private const val ACTION_QUIT_AV_IN = "quit_av_in"

  private const val PKG_IVI_SERVICES = "com.jancar.services"
  private const val ACTION_IVI_AVIN = "com.jancar.services.action.avin"

  // AIDL descriptors / transactions (from decompiled com.jancar.services.avin.IAVIn + IAVInCallback)
  private const val TOKEN_IAVIN = "com.jancar.services.avin.IAVIn"
  private const val TX_IAVIN_OPEN = 1
  private const val TX_IAVIN_CLOSE = 2
  private const val TX_IAVIN_IS_OPEN = 3

  private const val TOKEN_IAVIN_CALLBACK = "com.jancar.services.avin.IAVInCallback"

  // Jancar AV ids: 21 == AUX
  private const val AV_ID_AUX = 21

  override fun isSupported(context: Context): Boolean {
    val appContext = context.applicationContext

    // Prefer checking the explicit exported service (doesn't require intent resolution by action).
    if (canStartAutochipsService(appContext)) return true

    // Fallback: if we can bind to IVI AVIn service, we can operate.
    return bindIviAvIn(appContext, timeoutMs = 350L).isSuccess
  }

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    // 1) OEM-intended path: start Autochips AvInService open.
    runCatching {
      startAutochipsAvInService(appContext, ACTION_OPEN_AV_IN)
    }

    // 2) Verify (or fall back) via binder.
    while (System.currentTimeMillis() < deadline) {
      val isOpen = isAuxOpenViaBinder(appContext, perCallTimeoutMs = 250L).getOrNull()
      if (isOpen == true) return Result.success(true)
      try {
        Thread.sleep(60L)
      } catch (_: Throwable) {
      }
    }

    // 3) Fallback: direct binder open call (in case starting the proxy service is blocked).
    val binderOpenAttempt = openAuxViaBinder(appContext, timeoutMs = 800L)
    if (binderOpenAttempt.isSuccess) {
      val isOpenAfterFallback = isAuxOpenViaBinder(appContext, perCallTimeoutMs = 400L).getOrNull() == true
      return Result.success(isOpenAfterFallback)
    }

    return Result.success(false)
  }

  override fun exitAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    runCatching {
      startAutochipsAvInService(appContext, ACTION_QUIT_AV_IN)
    }

    while (System.currentTimeMillis() < deadline) {
      val isOpen = isAuxOpenViaBinder(appContext, perCallTimeoutMs = 250L).getOrNull()
      if (isOpen == false) return Result.success(true)
      try { Thread.sleep(60L) } catch (_: Throwable) {}
    }

    // Binder fallback: close directly
    runCatching {
      bindIviAvIn(appContext, timeoutMs = 700L).mapCatching { avin ->
        iAvInClose(avin, AV_ID_AUX).getOrThrow()
      }.getOrThrow()
    }

    val isOpenAfter = isAuxOpenViaBinder(appContext, perCallTimeoutMs = 400L).getOrNull()
    return Result.success(isOpenAfter == false)
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    return isAuxOpenViaBinder(appContext, perCallTimeoutMs = timeoutMs)
  }

  /**
   * Optional helper (not part of [HeadUnitAuxBackend]) to close/quit AUX-in.
   */
  fun exitAuxBlocking(context: Context, quit: Boolean = false): Result<Unit> {
    val appContext = context.applicationContext
    return runCatching {
      startAutochipsAvInService(appContext, if (quit) ACTION_QUIT_AV_IN else ACTION_CLOSE_AV_IN)
    }
  }

  private fun canStartAutochipsService(context: Context): Boolean {
    return try {
      val cn = ComponentName(PKG_AUTOCHIPS_BACKCAR, CLS_AUTOCHIPS_AVIN_SERVICE)
      @Suppress("DEPRECATION")
      context.packageManager.getServiceInfo(cn, 0)
      true
    } catch (_: Throwable) {
      false
    }
  }

  private fun startAutochipsAvInService(context: Context, action: String) {
    val intent = Intent(action).apply {
      component = ComponentName(PKG_AUTOCHIPS_BACKCAR, CLS_AUTOCHIPS_AVIN_SERVICE)
      `package` = PKG_AUTOCHIPS_BACKCAR
    }
    context.startService(intent)
  }

  private fun openAuxViaBinder(context: Context, timeoutMs: Long): Result<Unit> {
    return bindIviAvIn(context, timeoutMs).mapCatching { avin ->
      val cb = NoopAvInCallback()
      iAvInOpen(avin, AV_ID_AUX, cb, context.packageName).getOrThrow()
    }
  }

  private fun isAuxOpenViaBinder(context: Context, perCallTimeoutMs: Long): Result<Boolean> {
    return bindIviAvIn(context, timeoutMs = perCallTimeoutMs).mapCatching { avin ->
      iAvInIsOpen(avin, AV_ID_AUX).getOrThrow()
    }
  }

  private fun bindIviAvIn(context: Context, timeoutMs: Long): Result<IBinder> {
    val latch = CountDownLatch(1)
    var binder: IBinder? = null
    var bindError: Throwable? = null

    val conn = object : ServiceConnection {
      override fun onServiceConnected(name: ComponentName, service: IBinder) {
        binder = service
        latch.countDown()
      }

      override fun onServiceDisconnected(name: ComponentName) {
        // ignore
      }

      override fun onNullBinding(name: ComponentName) {
        bindError = IllegalStateException("Null binding for $name")
        latch.countDown()
      }
    }

    return try {
      val intent = Intent(ACTION_IVI_AVIN).setPackage(PKG_IVI_SERVICES)
      val ok = context.bindService(intent, conn, Context.BIND_AUTO_CREATE)
      if (!ok) return Result.failure(Exception("bindService returned false for $intent"))
      if (!latch.await(timeoutMs.coerceAtLeast(100L), TimeUnit.MILLISECONDS)) {
        return Result.failure(Exception("bindService timed out for $intent"))
      }
      bindError?.let { return Result.failure(it) }
      binder?.let { Result.success(it) }
        ?: Result.failure(Exception("Binder was null after service connection for $intent"))
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      try {
        context.unbindService(conn)
      } catch (_: Throwable) {
      }
    }
  }

  private fun iAvInOpen(avin: IBinder, avId: Int, callback: IBinder, packageName: String): Result<Unit> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_IAVIN)
      data.writeInt(avId)
      data.writeStrongBinder(callback)
      data.writeString(packageName)
      avin.transact(TX_IAVIN_OPEN, data, reply, 0)
      reply.readException()
      Result.success(Unit)
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  private fun iAvInIsOpen(avin: IBinder, avId: Int): Result<Boolean> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_IAVIN)
      data.writeInt(avId)
      avin.transact(TX_IAVIN_IS_OPEN, data, reply, 0)
      reply.readException()
      Result.success(reply.readInt() != 0)
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  @Suppress("unused")
  private fun iAvInClose(avin: IBinder, avId: Int): Result<Unit> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_IAVIN)
      data.writeInt(avId)
      avin.transact(TX_IAVIN_CLOSE, data, reply, 0)
      reply.readException()
      Result.success(Unit)
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  /**
   * Minimal callback binder to satisfy IAVIn.open(). The service's BaseService.addDeviceNode()
   * tolerates null, but providing a binder avoids any OEM variations that assume non-null.
   */
  private class NoopAvInCallback : Binder(), IInterface {
    init {
      attachInterface(this, TOKEN_IAVIN_CALLBACK)
    }

    override fun asBinder(): IBinder = this

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
      if (code == INTERFACE_TRANSACTION) {
        reply?.writeString(TOKEN_IAVIN_CALLBACK)
        return true
      }
      // Ignore all callbacks.
      return try {
        data.enforceInterface(TOKEN_IAVIN_CALLBACK)
        reply?.writeNoException()
        true
      } catch (_: Throwable) {
        // If enforceInterface fails, still don't crash the caller.
        reply?.writeNoException()
        true
      }
    }
  }
}

