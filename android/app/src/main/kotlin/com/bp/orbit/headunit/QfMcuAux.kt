package com.bp.orbit.headunit

import android.content.Context
import android.content.pm.PackageManager
import android.os.IBinder
import java.lang.reflect.InvocationTargetException

/**
 * QF (Quectel) units, Aux is primarily an MCU audio-channel switch
 */
object QfMcuAux : HeadUnitAuxBackend {
  override val id: String = "qf_mcu"

  private const val SERVICE_NAME = "mcu_service"

  private const val PKG_QF_BACKCAR = "com.qf.backcar"
  private const val PKG_QF_FRAMEWORK = "com.qf.framework"

  private const val CHANNEL_AUX_1 = 1
  private const val CHANNEL_AUX_3 = 3
  private const val CHANNEL_MEDIA = 4

  override fun isSupported(context: Context): Boolean {
    val appContext = context.applicationContext
    val pm = appContext.packageManager

    // Reduce false-positives
    val looksLikeQf = hasPackage(pm, PKG_QF_FRAMEWORK) || hasPackage(pm, PKG_QF_BACKCAR)
    if (!looksLikeQf) return false

    return getMcuManagerInterface(appContext) != null
  }

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val mcu = getMcuManagerInterface(appContext)
      ?: return Result.failure(IllegalStateException("QF mcu_service not available"))

    return runCatching {
      // Switch channel
      invokeRpcSetChannel(mcu, CHANNEL_AUX_1).getOrThrow()

      // Verify by reading channel back
      val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(200L)
      while (System.currentTimeMillis() < deadline) {
        val ch = invokeRpcGetChannel(mcu).getOrNull()
        if (ch == CHANNEL_AUX_1 || ch == CHANNEL_AUX_3) return@runCatching true
        try {
          Thread.sleep(50L)
        } catch (_: Throwable) {
        }
      }

      // If we can't read it back (or it didn't change in time), treat as failure
      val last = invokeRpcGetChannel(mcu).getOrNull()
      last == CHANNEL_AUX_1 || last == CHANNEL_AUX_3
    }
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val mcu = getMcuManagerInterface(appContext)
      ?: return Result.failure(IllegalStateException("QF mcu_service not available"))

    return invokeRpcGetChannel(mcu).map { ch ->
      ch == CHANNEL_AUX_1 || ch == CHANNEL_AUX_3
    }
  }

  fun exitAuxBlocking(context: Context): Result<Unit> {
    val appContext = context.applicationContext
    val mcu = getMcuManagerInterface(appContext)
      ?: return Result.failure(IllegalStateException("QF mcu_service not available"))
    return invokeRpcSetChannel(mcu, CHANNEL_MEDIA)
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

  private fun getMcuManagerInterface(context: Context): Any? {
    // Try public Context hook
    try {
      val svc = context.getSystemService(SERVICE_NAME)
      if (svc != null && hasRpcMethods(svc)) return svc
    } catch (_: Throwable) {
      // Ignore
    }

    // Fallback to hidden ServiceManager binder + AIDL Stub.asInterface
    return try {
      val binder = getServiceManagerBinder(SERVICE_NAME) ?: return null
      val stubCls = Class.forName("android.qf.mcu.IMcuManager\$Stub")
      val asInterface = stubCls.getMethod("asInterface", IBinder::class.java)
      val iface = asInterface.invoke(null, binder)
      if (iface != null && hasRpcMethods(iface)) iface else null
    } catch (_: Throwable) {
      null
    }
  }

  private fun hasRpcMethods(target: Any): Boolean {
    val cls = target.javaClass
    val hasSet = cls.methods.any { it.name == "RPC_SetChannel" && it.parameterTypes.size == 1 }
    val hasGet = cls.methods.any { it.name == "RPC_GetChannel" && it.parameterTypes.isEmpty() }
    return hasSet && hasGet
  }

  private fun getServiceManagerBinder(serviceName: String): IBinder? {
    val sm = Class.forName("android.os.ServiceManager")
    val m = sm.getMethod("getService", String::class.java)
    return m.invoke(null, serviceName) as? IBinder
  }

  private fun invokeRpcSetChannel(target: Any, mode: Int): Result<Unit> {
    return runCatching {
      val cls = target.javaClass

      try {
        val m = cls.getMethod("RPC_SetChannel", Byte::class.javaPrimitiveType)
        m.invoke(target, mode.toByte())
        return@runCatching
      } catch (_: NoSuchMethodException) {
        // Try next
      }

      // Alternate signature
      val m2 = cls.getMethod("RPC_SetChannel", Int::class.javaPrimitiveType)
      m2.invoke(target, mode)
    }.mapCatching {
      // Unwrap to surface real RemoteException messages
      Unit
    }.recoverCatching { t ->
      throw unwrapInvocation(t)
    }
  }

  private fun invokeRpcGetChannel(target: Any): Result<Int> {
    return runCatching {
      val cls = target.javaClass
      val m = cls.getMethod("RPC_GetChannel")
      val v = m.invoke(target)
      when (v) {
        is Byte -> v.toInt() and 0xFF
        is Int -> v
        is Number -> v.toInt()
        else -> error("Unexpected RPC_GetChannel return type: ${v?.javaClass}")
      }
    }.recoverCatching { t ->
      throw unwrapInvocation(t)
    }
  }

  private fun unwrapInvocation(t: Throwable): Throwable {
    return if (t is InvocationTargetException && t.targetException != null) {
      t.targetException
    } else {
      t
    }
  }
}

