package com.bp.orbit.headunit

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * FYT Aux input switching via com.syu.ms binder IPC
 */
object FytSyuMsAux : HeadUnitAuxBackend {
  override val id: String = "fyt_syu_ms"
  private const val PKG_MS = "com.syu.ms"
  private const val CLS_TOOLKIT = "app.ToolkitService"

  // ModuleService action that returns the "main" module binder directly
  private const val ACTION_MS_MAIN = "com.syu.ms.main"

  private const val TOKEN_TOOLKIT = "com.syu.ipc.IRemoteToolkit"
  private const val TOKEN_MODULE = "com.syu.ipc.IRemoteModule"

  private const val APP_ID_AUX = 5

  override fun isSupported(context: Context): Boolean {
    val pm = context.packageManager
    return try {
      @Suppress("DEPRECATION")
      pm.getPackageInfo(PKG_MS, 0)
      true
    } catch (_: Throwable) {
      false
    }
  }

  /**
   * Switch to aux input and return whether aux is active.
   */
  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext

    // 1) Try ToolkitService path
    val moduleViaToolkitResult = bindAndGetMainModuleViaToolkit(appContext, timeoutMs)
    if (moduleViaToolkitResult.isSuccess) {
      return switchAndReadBack(moduleViaToolkitResult.getOrThrow())
    }

    // 2) Fallback, bind ModuleService by action "com.syu.ms.main"
    val moduleViaActionResult = bindByActionGetModule(appContext, ACTION_MS_MAIN, timeoutMs)
    if (moduleViaActionResult.isSuccess) {
      return switchAndReadBack(moduleViaActionResult.getOrThrow())
    }

    return Result.failure(
      moduleViaActionResult.exceptionOrNull()
        ?: moduleViaToolkitResult.exceptionOrNull()
        ?: Exception("Failed to connect to module service")
    )
  }

   /**
   * Read current AppId without switching
   */
  private fun readCurrentSourceIdBlocking(context: Context, timeoutMs: Long): Result<Int> {
    val appContext = context.applicationContext

    val moduleViaToolkitResult = bindAndGetMainModuleViaToolkit(appContext, timeoutMs)
    if (moduleViaToolkitResult.isSuccess) {
      return getInt0(moduleViaToolkitResult.getOrThrow(), 0)
    }

    val moduleViaActionResult = bindByActionGetModule(appContext, ACTION_MS_MAIN, timeoutMs)
    if (moduleViaActionResult.isSuccess) {
      return getInt0(moduleViaActionResult.getOrThrow(), 0)
    }

    return Result.failure(
      moduleViaActionResult.exceptionOrNull()
        ?: moduleViaToolkitResult.exceptionOrNull()
        ?: Exception("Failed to connect to module service")
    )
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return readCurrentSourceIdBlocking(context, timeoutMs).map { it == APP_ID_AUX }
  }

  private fun switchAndReadBack(mainModule: IBinder): Result<Boolean> {
    // Enable aux input feature
    cmdOneWay(mainModule, 47, intArrayOf(1))

    // Switch source to aux
    cmdOneWay(mainModule, 0, intArrayOf(APP_ID_AUX))

    // Give MCU a moment
    try {
      Thread.sleep(200L)
    } catch (_: Throwable) {}

    // Read back current AppId and convert to boolean aux-active state
    return getInt0(mainModule, 0).map { it == APP_ID_AUX }
  }

  private fun bindAndGetMainModuleViaToolkit(context: Context, timeoutMs: Long): Result<IBinder> {
    return bindByComponent(context, ComponentName(PKG_MS, CLS_TOOLKIT), timeoutMs).mapCatching {
      getRemoteModule0(it).getOrThrow()
    }
  }

  private fun bindByActionGetModule(context: Context, action: String, timeoutMs: Long): Result<IBinder> {
    val intent = Intent(action).setPackage(PKG_MS)
    return bindByIntent(context, intent, timeoutMs)
  }

  private fun bindByComponent(context: Context, component: ComponentName, timeoutMs: Long): Result<IBinder> {
    val intent = Intent().setComponent(component)
    return bindByIntent(context, intent, timeoutMs)
  }

  private fun bindByIntent(context: Context, intent: Intent, timeoutMs: Long): Result<IBinder> {
    val latch = CountDownLatch(1)
    var binder: IBinder? = null

    val conn = object : ServiceConnection {
      override fun onServiceConnected(name: ComponentName, service: IBinder) {
        binder = service
        latch.countDown()
      }

      override fun onServiceDisconnected(name: ComponentName) {
        // Ignore for now
      }
    }

    return try {
      val ok = context.bindService(intent, conn, Context.BIND_AUTO_CREATE)
      if (!ok) return Result.failure(Exception("bindService returned false for $intent"))
      if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
        return Result.failure(Exception("bindService timed out for $intent"))
      }
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

  // IRemoteToolkit.getRemoteModule(0) returns IRemoteModule binder
  private fun getRemoteModule0(toolkit: IBinder): Result<IBinder> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_TOOLKIT)
      data.writeInt(0) // moduleCode
      toolkit.transact(1, data, reply, 0) // TRANSACTION_getRemoteModule = 1
      reply.readException()
      val b = reply.readStrongBinder()
      if (b != null) Result.success(b) else Result.failure(Exception("getRemoteModule0 returned null binder"))
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }

  // IRemoteModule.cmd(cmdCode, ints, flts, strs) — this interface is effectively one-way
  private fun cmdOneWay(module: IBinder, cmdCode: Int, ints: IntArray?) {
    val data = Parcel.obtain()
    try {
      data.writeInterfaceToken(TOKEN_MODULE)
      data.writeInt(cmdCode)
      data.writeIntArray(ints)
      data.writeFloatArray(null)
      data.writeStringArray(null)
      module.transact(1, data, null, IBinder.FLAG_ONEWAY) // TRANSACTION_cmd = 1
    } finally {
      data.recycle()
    }
  }

  // IRemoteModule.get(getCode, ...) returns a parcelled object with int[]/float[]/String[]
  private fun getInt0(module: IBinder, getCode: Int): Result<Int> {
    val data = Parcel.obtain()
    val reply = Parcel.obtain()
    return try {
      data.writeInterfaceToken(TOKEN_MODULE)
      data.writeInt(getCode)
      data.writeIntArray(null)
      data.writeFloatArray(null)
      data.writeStringArray(null)

      module.transact(2, data, reply, 0) // TRANSACTION_get = 2
      reply.readException()

      val present = reply.readInt()
      if (present == 0) return Result.failure(Exception("getInt0 received no data"))

      val ints = reply.createIntArray()
      val v = ints?.getOrNull(0)
      if (v != null) Result.success(v) else Result.failure(Exception("getInt0 received null or empty array"))
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      reply.recycle()
      data.recycle()
    }
  }
}