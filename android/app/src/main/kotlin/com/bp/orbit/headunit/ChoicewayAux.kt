package com.bp.orbit.headunit

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Binder
import android.os.IBinder
import android.os.IInterface
import android.os.Parcel
import android.os.UserHandle
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Choiceway AUX-in
 */
object ChoicewayAux : HeadUnitAuxBackend {
  override val id: String = "choiceway_eventcenter"

  private const val PKG_EVENT_CENTER = "com.szchoiceway.eventcenter"
  private const val ACTION_EVENT_SERVICE = "com.szchoiceway.eventcenter.EventService"

  private const val TOKEN_IEVENT = "com.szchoiceway.eventcenter.IEventService"
  private const val TOKEN_ICALLBACK = "com.szchoiceway.eventcenter.ICallbackfn"

  private const val TX_SEND_MODE = 1
  private const val TX_SET_CUR_MODE_CALLBACK = 30
  private const val TX_EXIT_CUR_MODE = 31
  private const val TX_GET_VALID_MODE = 46

  private const val TX_CALLBACK_NOTIFY_EVT = 1
  private const val TX_CALLBACK_CHECK_IS_ACTIVE = 2

  private const val SRC_AUX = 40
  private const val SRC_NULL = 99

  private const val ACTION_MCU_CMD_EVENT =
    "com.szchoiceway.eventcenter.EventUtils.ACTION_MCU_CMD_EVENT"
  private const val EXTRA_MCU_CMD_DATA = "EventUtils.MCU_CMD_DATA"

  // Broadcasts that drive EventCenter MIPI Aux overlay
  private const val ACTION_EXIT_AUX_WIN = "com.szchoiceway.action.EXIT_AUX_WIN"

  // Keep alive for the process so EventCenter can call back while Aux is claimed
  private val modeCallback: IBinder = ModeCallbackBinder()

  override fun isSupported(context: Context): Boolean {
    val appContext = context.applicationContext
    val pm = appContext.packageManager
    if (!hasPackage(pm, PKG_EVENT_CENTER)) return false
    if (!canResolveEventService(pm)) return false
    return bindEventService(appContext, timeoutMs = 350L).isSuccess
  }

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    val binderResult = bindEventService(appContext, timeoutMs = timeoutMs.coerceAtMost(1200L))
    if (binderResult.isFailure) return Result.failure(binderResult.exceptionOrNull()!!)
    val svc = binderResult.getOrThrow()

    // Claim the mode and notify MCU through EventCenter
    val claim = setCurModeCallback(svc, SRC_AUX, modeCallback)
    if (claim.isFailure) return Result.failure(claim.exceptionOrNull()!!)
    sendMode(svc, SRC_AUX, waitAck = false)

    // Supplemental MCU packets for UI variants where sendMode doesn't do anything
    sendMcuModePackets(appContext, enterAux = true)

    while (System.currentTimeMillis() < deadline) {
      val mode = getValidMode(svc).getOrNull()
      if (mode == SRC_AUX) return Result.success(true)
      try {
        Thread.sleep(60L)
      } catch (_: Throwable) {
      }
    }

    return getValidMode(svc).map { it == SRC_AUX }
  }

  override fun exitAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    val binderResult = bindEventService(appContext, timeoutMs = timeoutMs.coerceAtMost(1200L))
    if (binderResult.isFailure) return Result.failure(binderResult.exceptionOrNull()!!)
    val svc = binderResult.getOrThrow()

    val current = getValidMode(svc).getOrNull()
    if (current != null && current != SRC_AUX) {
      // Ask EventCenter to drop any Aux overlay anyway
      sendBroadcastSafe(appContext, Intent(ACTION_EXIT_AUX_WIN))
      return Result.success(true)
    }

    val exitRes = exitCurMode(svc, SRC_AUX)
    if (exitRes.isFailure) return Result.failure(exitRes.exceptionOrNull()!!)

    sendMcuModePackets(appContext, enterAux = false)
    sendBroadcastSafe(appContext, Intent(ACTION_EXIT_AUX_WIN))

    while (System.currentTimeMillis() < deadline) {
      val mode = getValidMode(svc).getOrNull()
      if (mode != null && mode != SRC_AUX) return Result.success(true)
      try {
        Thread.sleep(60L)
      } catch (_: Throwable) {
      }
    }

    return getValidMode(svc).map { it != SRC_AUX }
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    return bindEventService(appContext, timeoutMs).mapCatching { svc ->
      getValidMode(svc).getOrThrow() == SRC_AUX
    }
  }

  private fun hasPackage(pm: PackageManager, pkg: String): Boolean {
    return try {
      @Suppress("DEPRECATION")
      pm.getPackageInfo(pkg, 0)
      true
    } catch (_: Throwable) {
      false
    }
  }

  private fun canResolveEventService(pm: PackageManager): Boolean {
    return try {
      val intent = Intent(ACTION_EVENT_SERVICE).setPackage(PKG_EVENT_CENTER)
      @Suppress("DEPRECATION")
      pm.resolveService(intent, 0) != null
    } catch (_: Throwable) {
      false
    }
  }

  private fun bindEventService(context: Context, timeoutMs: Long): Result<IBinder> {
    val latch = CountDownLatch(1)
    var binder: IBinder? = null
    var bindError: Throwable? = null

    val conn = object : ServiceConnection {
      override fun onServiceConnected(name: ComponentName, service: IBinder) {
        binder = service
        latch.countDown()
      }

      override fun onServiceDisconnected(name: ComponentName) {
        // Ignore
      }

      override fun onNullBinding(name: ComponentName) {
        bindError = IllegalStateException("Null binding for $name")
        latch.countDown()
      }
    }

    return try {
      val intent = Intent(ACTION_EVENT_SERVICE).setPackage(PKG_EVENT_CENTER)
      val ok = context.bindService(intent, conn, Context.BIND_AUTO_CREATE)
      if (!ok) return Result.failure(Exception("bindService returned false for $intent"))
      if (!latch.await(timeoutMs.coerceAtLeast(150L), TimeUnit.MILLISECONDS)) {
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

  private fun sendMode(service: IBinder, mode: Int, waitAck: Boolean): Result<Unit> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_IEVENT)
      data.writeInt(mode)
      data.writeInt(if (waitAck) 1 else 0)
      service.transact(TX_SEND_MODE, data, reply, 0)
      reply.readException()
      Result.success(Unit)
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  private fun setCurModeCallback(service: IBinder, mode: Int, callback: IBinder): Result<Unit> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_IEVENT)
      data.writeInt(mode)
      data.writeStrongBinder(callback)
      service.transact(TX_SET_CUR_MODE_CALLBACK, data, reply, 0)
      reply.readException()
      Result.success(Unit)
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  private fun exitCurMode(service: IBinder, mode: Int): Result<Unit> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_IEVENT)
      data.writeInt(mode)
      service.transact(TX_EXIT_CUR_MODE, data, reply, 0)
      reply.readException()
      Result.success(Unit)
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  private fun getValidMode(service: IBinder): Result<Int> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_IEVENT)
      service.transact(TX_GET_VALID_MODE, data, reply, 0)
      reply.readException()
      Result.success(reply.readInt())
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  private fun sendMcuModePackets(context: Context, enterAux: Boolean) {
    val mode = if (enterAux) SRC_AUX else SRC_NULL
    val kswMode: Byte = if (enterAux) 6 else 13

    sendMcuData(context, byteArrayOf(0x01, mode.toByte()))
    sendMcuData(
      context,
      byteArrayOf(
        0xF2.toByte(),
        0x00,
        0x67, // MCU_KEY_SEEK_UP
        0x01,
        kswMode,
      ),
    )
  }

  private fun sendMcuData(context: Context, payload: ByteArray) {
    try {
      val intent = Intent(ACTION_MCU_CMD_EVENT).putExtra(EXTRA_MCU_CMD_DATA, payload)
      sendBroadcastSafe(context, intent)
    } catch (_: Throwable) {
    }
  }

  private fun sendBroadcastSafe(context: Context, intent: Intent) {
    try {
      // Prefer all users when available
      val method = Context::class.java.getMethod(
        "sendBroadcastAsUser",
        Intent::class.java,
        UserHandle::class.java,
      )
      val all = UserHandle::class.java.getField("ALL").get(null) as UserHandle
      method.invoke(context, intent, all)
    } catch (_: Throwable) {
      try {
        context.sendBroadcast(intent)
      } catch (_: Throwable) {
      }
    }
  }

  private class ModeCallbackBinder : Binder(), IInterface {
    init {
      attachInterface(this, TOKEN_ICALLBACK)
    }

    override fun asBinder(): IBinder = this

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
      when (code) {
        INTERFACE_TRANSACTION -> {
          reply?.writeString(TOKEN_ICALLBACK)
          return true
        }
        TX_CALLBACK_NOTIFY_EVT -> {
          data.enforceInterface(TOKEN_ICALLBACK)
          // int evt, int, int, byte[], String — ignore
          data.readInt()
          data.readInt()
          data.readInt()
          data.createByteArray()
          data.readString()
          reply?.writeNoException()
          return true
        }
        TX_CALLBACK_CHECK_IS_ACTIVE -> {
          data.enforceInterface(TOKEN_ICALLBACK)
          reply?.writeNoException()
          reply?.writeInt(1)
          return true
        }
      }
      return super.onTransact(code, data, reply, flags)
    }
  }
}
