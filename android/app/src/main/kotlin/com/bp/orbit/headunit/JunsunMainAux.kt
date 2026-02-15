package com.bp.orbit.headunit

import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.os.Parcel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Junsun V1 / V1 Pro
 */
object JunsunMainAux : HeadUnitAuxBackend {
  override val id: String = "junsun_ts_mainui"

  private const val PKG_MAINUI = "com.ts.MainUI"
  private const val ACTION_MAIN_UI = "android.intent.action.MAIN_UI"

  private const val TOKEN_TSCOMMON = "com.ts.main.common.ITsCommon"

  private const val TX_ENTER_MODE = 1
  private const val TX_GET_WORK_MODE = 10

  // Workmode 8 == AUX2
  private const val WORKMODE_AUX = 8
  // Workmode 0 == "None/Home"
  private const val WORKMODE_EXIT = 0

  override fun isSupported(context: Context): Boolean {
    val appContext = context.applicationContext
    val pm = appContext.packageManager

    if (!hasPackage(pm, PKG_MAINUI)) return false
    if (!canResolveMainUiService(pm)) return false

    // If we can bind and read workmode, we're good
    return bindMainUi(appContext, timeoutMs = 350L).isSuccess
  }

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    val binderResult = bindMainUi(appContext, timeoutMs = timeoutMs.coerceAtMost(1200L))
    if (binderResult.isFailure) return Result.failure(binderResult.exceptionOrNull()!!)
    val svc = binderResult.getOrThrow()

    // Switch
    val enterRes = enterMode(svc, WORKMODE_AUX)
    if (enterRes.isFailure) return Result.failure(enterRes.exceptionOrNull()!!)

    // Verify
    while (System.currentTimeMillis() < deadline) {
      val mode = getWorkMode(svc).getOrNull()
      if (mode == WORKMODE_AUX) return Result.success(true)
      try {
        Thread.sleep(60L)
      } catch (_: Throwable) {
      }
    }

    return getWorkMode(svc).map { it == WORKMODE_AUX }
  }

  override fun exitAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    val binderResult = bindMainUi(appContext, timeoutMs = timeoutMs.coerceAtMost(1200L))
    if (binderResult.isFailure) return Result.failure(binderResult.exceptionOrNull()!!)
    val svc = binderResult.getOrThrow()

    val current = getWorkMode(svc).getOrNull()
    if (current != WORKMODE_AUX) return Result.success(true)

    val exitRes = enterMode(svc, WORKMODE_EXIT)
    if (exitRes.isFailure) return Result.failure(exitRes.exceptionOrNull()!!)

    while (System.currentTimeMillis() < deadline) {
      val mode = getWorkMode(svc).getOrNull()
      if (mode != null && mode != WORKMODE_AUX) return Result.success(true)
      try {
        Thread.sleep(60L)
      } catch (_: Throwable) {
      }
    }

    return getWorkMode(svc).map { it != WORKMODE_AUX }
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    return bindMainUi(appContext, timeoutMs).mapCatching { svc ->
      getWorkMode(svc).getOrThrow() == WORKMODE_AUX
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

  private fun canResolveMainUiService(pm: PackageManager): Boolean {
    return try {
      val intent = Intent(ACTION_MAIN_UI).setPackage(PKG_MAINUI)
      @Suppress("DEPRECATION")
      pm.resolveService(intent, 0) != null
    } catch (_: Throwable) {
      false
    }
  }

  private fun bindMainUi(context: Context, timeoutMs: Long): Result<IBinder> {
    val latch = CountDownLatch(1)
    var binder: IBinder? = null
    var bindError: Throwable? = null

    val conn = object : ServiceConnection {
      override fun onServiceConnected(name: android.content.ComponentName, service: IBinder) {
        binder = service
        latch.countDown()
      }

      override fun onServiceDisconnected(name: android.content.ComponentName) {
        // Ignore
      }

      override fun onNullBinding(name: android.content.ComponentName) {
        bindError = IllegalStateException("Null binding for $name")
        latch.countDown()
      }
    }

    return try {
      val intent = Intent(ACTION_MAIN_UI).setPackage(PKG_MAINUI)
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

  private fun enterMode(service: IBinder, mode: Int): Result<Unit> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_TSCOMMON)
      data.writeInt(mode)
      service.transact(TX_ENTER_MODE, data, reply, 0)
      reply.readException()
      Result.success(Unit)
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  private fun getWorkMode(service: IBinder): Result<Int> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_TSCOMMON)
      service.transact(TX_GET_WORK_MODE, data, reply, 0)
      reply.readException()
      Result.success(reply.readInt())
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }
}

