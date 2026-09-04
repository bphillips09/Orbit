package com.bp.orbit.headunit

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.IBinder
import android.os.Parcel
import android.provider.Settings
import java.lang.reflect.Modifier
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * HCN / HC Auto Aux-in
 */
object HcnSourceAux : HeadUnitAuxBackend {
  override val id: String = "hcn_sourceinfo"

  private const val PKG_AUX = "com.hcn.audioinputsource"
  private const val CLS_AUX_SERVICE = "com.hcn.audioinputsource.AudioInputSourceService"
  private const val TOKEN_IAUDIO_INPUT = "com.hcn.audioinputsource.IAudioInputService"

  private const val CLS_SOURCE_INFO = "android.sourceservice.SourceInfo"
  private const val CLS_SOURCE_SERVICE = "android.sourceservice.SourceService"
  private const val CLS_SOURCE_PATH = "android.sourceservice.SourceService\$PATH"
  private const val CLS_EXT_AUDIO_MUXER = "android.sourceservice.ExtAudioMuxer"
  private const val CLS_HCONSTANT = "android.Configures.HConstant"
  private const val CLS_HCONFIG = "android.Configures.HConfig"

  private const val SETTING_AUX_AUDIO_STATUS = "aux_audio_status"
  private const val SETTING_MCU_AUX_MODE = "hcnhw/mcu_aux_mode"

  private const val TX_START_AUX_RECORD = 1
  private const val TX_STOP_AUX_RECORD = 2

  override fun isSupported(context: Context): Boolean {
    val appContext = context.applicationContext
    if (hasPackage(appContext, PKG_AUX)) return true
    if (classExists(CLS_SOURCE_INFO) || classExists(CLS_EXT_AUDIO_MUXER)) return true
    return hasPackage(appContext, "com.hcn.autosource")
  }

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    runCatching { changeSourceToAux(appContext) }
    runCatching { requestAuxMux(appContext) }
    runCatching { sendExtAudioMux(enter = true) }

    if (isAuxActive(appContext) != true) {
      runCatching { startAuxRecordViaService(appContext, timeoutMs.coerceAtMost(800L)) }
    }

    while (System.currentTimeMillis() < deadline) {
      if (isAuxActive(appContext) == true) return Result.success(true)
      try {
        Thread.sleep(60L)
      } catch (_: Throwable) {
      }
    }

    return Result.success(isAuxActive(appContext) == true)
  }

  override fun exitAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    val appContext = context.applicationContext
    val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(300L)

    if (isAuxActive(appContext) == false) return Result.success(true)

    runCatching { stopAuxRecordViaService(appContext, timeoutMs.coerceAtMost(800L)) }
    runCatching { sendExtAudioMux(enter = false) }
    runCatching { changeSourceAwayFromAux(appContext) }

    while (System.currentTimeMillis() < deadline) {
      if (isAuxActive(appContext) == false) return Result.success(true)
      try {
        Thread.sleep(60L)
      } catch (_: Throwable) {
      }
    }

    return Result.success(isAuxActive(appContext) != true)
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return runCatching {
      isAuxActive(context.applicationContext) ?: error("Unable to query HCN aux source state")
    }
  }

  private fun isAuxActive(context: Context): Boolean? {
    val sourceAux = intConst("SOURCE_AUX")
    val current = readCurrentSource(context)
    if (sourceAux != null && current != null) return current == sourceAux

    val status = settingsInt(context, SETTING_AUX_AUDIO_STATUS)
    if (status != null) return status != 0

    val mcuMode = settingsInt(context, SETTING_MCU_AUX_MODE)
      ?: hConfigInt("mcu_aux_mode")
      ?: hConfigInt(SETTING_MCU_AUX_MODE)
    if (mcuMode != null) return mcuMode != 0

    if (current != null) {
      val nullSrc = intConst("SOURCE_NULL")
      if (nullSrc != null && current == nullSrc) return false
    }

    return null
  }

  private fun changeSourceToAux(context: Context) {
    val aux = intConst("SOURCE_AUX") ?: return
    val info = sourceInfo(context) ?: return
    invokeIntSource(info, listOf("changeSource", "setSource"), aux)
  }

  private fun changeSourceAwayFromAux(context: Context) {
    val info = sourceInfo(context) ?: return
    val away = intConst("SOURCE_NULL")
      ?: intConst("SOURCE_USB")
      ?: intConst("SOURCE_THE3PART")
      ?: return
    invokeIntSource(info, listOf("changeSource", "setSource"), away)
  }

  private fun requestAuxMux(context: Context) {
    val path = pathEnum("AUX") ?: return
    val hosts = listOfNotNull(
      runCatching { sourceInfo(context) }.getOrNull(),
      runCatching { singleton(Class.forName(CLS_SOURCE_SERVICE), context) }.getOrNull(),
    )
    for (host in hosts) {
      for (m in host.javaClass.methods.filter { it.name == "requestSourceMux" }) {
        val params = m.parameterTypes
        if (params.size == 1 && params[0].isInstance(path)) {
          m.invoke(host, path)
          return
        }
        if (params.size == 1 && params[0].name == "java.util.EnumSet") {
          val set = Class.forName("java.util.EnumSet")
            .getMethod("of", Enum::class.java)
            .invoke(null, path as Enum<*>)
          m.invoke(host, set)
          return
        }
      }
    }
  }

  private fun sendExtAudioMux(enter: Boolean) {
    val cls = Class.forName(CLS_EXT_AUDIO_MUXER)
    runCatching {
      val init = cls.methods.firstOrNull { it.name == "nativeInit" && it.parameterTypes.isEmpty() }
      val muxer = singleton(cls) ?: runCatching { cls.getDeclaredConstructor().apply { isAccessible = true }.newInstance() }.getOrNull()
      if (muxer != null) init?.invoke(muxer) else init?.invoke(null)
    }

    val path = if (enter) {
      intConst("PATH_AUX") ?: pathEnum("AUX")?.let { enumOrdinalOrValue(it) }
    } else {
      intConst("PATH_MUSIC") ?: pathEnum("MUSIC")?.let { enumOrdinalOrValue(it) }
    } ?: if (enter) 0 else 1

    val send = cls.methods.firstOrNull { m ->
      m.name == "SendCmdAudioMux" && m.parameterTypes.size == 2
    } ?: return

    val target = if (Modifier.isStatic(send.modifiers)) null else singleton(cls)
    val p0 = send.parameterTypes[0]
    val p1 = send.parameterTypes[1]
    val arg0: Any = if (p0 == Int::class.javaPrimitiveType || p0 == Integer.TYPE) {
      path
    } else {
      pathEnum(if (enter) "AUX" else "MUSIC") ?: return
    }
    val arg1: Any = when {
      p1 == IntArray::class.java -> intArrayOf()
      p1 == Int::class.javaPrimitiveType || p1 == Integer.TYPE -> 1
      else -> intArrayOf(1)
    }
    send.invoke(target, arg0, arg1)
  }

  private fun startAuxRecordViaService(context: Context, timeoutMs: Long) {
    transactAuxService(context, timeoutMs, TX_START_AUX_RECORD) { data ->
      data.writeInt(AudioManager.STREAM_MUSIC)
    }.getOrThrow()
  }

  private fun stopAuxRecordViaService(context: Context, timeoutMs: Long) {
    transactAuxService(context, timeoutMs, TX_STOP_AUX_RECORD, writeArgs = null).getOrThrow()
  }

  private fun transactAuxService(
    context: Context,
    timeoutMs: Long,
    code: Int,
    writeArgs: ((Parcel) -> Unit)?,
  ): Result<Unit> {
    val latch = CountDownLatch(1)
    var binder: IBinder? = null
    var bindError: Throwable? = null

    val conn = object : ServiceConnection {
      override fun onServiceConnected(name: ComponentName, service: IBinder) {
        binder = service
        latch.countDown()
      }

      override fun onServiceDisconnected(name: ComponentName) {}

      override fun onNullBinding(name: ComponentName) {
        bindError = IllegalStateException("Null binding for $name")
        latch.countDown()
      }
    }

    return try {
      val intent = Intent().setComponent(ComponentName(PKG_AUX, CLS_AUX_SERVICE))
      val ok = context.bindService(intent, conn, Context.BIND_AUTO_CREATE)
      if (!ok) return Result.failure(Exception("bindService returned false for $intent"))
      if (!latch.await(timeoutMs.coerceAtLeast(150L), TimeUnit.MILLISECONDS)) {
        return Result.failure(Exception("bindService timed out for $intent"))
      }
      bindError?.let { return Result.failure(it) }
      val svc = binder ?: return Result.failure(Exception("Binder was null after connecting to $intent"))

      val data = Parcel.obtain()
      val reply = Parcel.obtain()
      try {
        data.writeInterfaceToken(TOKEN_IAUDIO_INPUT)
        writeArgs?.invoke(data)
        svc.transact(code, data, reply, 0)
        reply.readException()
        Result.success(Unit)
      } finally {
        reply.recycle()
        data.recycle()
      }
    } catch (t: Throwable) {
      Result.failure(t)
    } finally {
      try {
        context.unbindService(conn)
      } catch (_: Throwable) {
      }
    }
  }

  private fun sourceInfo(context: Context): Any? {
    return singleton(Class.forName(CLS_SOURCE_INFO), context)
  }

  private fun readCurrentSource(context: Context): Int? {
    val info = runCatching { sourceInfo(context) }.getOrNull() ?: return null
    for (name in listOf("getSource", "curSource", "getCurrentSource")) {
      val m = info.javaClass.methods.firstOrNull { it.name == name && it.parameterTypes.isEmpty() }
        ?: continue
      val v = runCatching { m.invoke(info) }.getOrNull() ?: continue
      when (v) {
        is Int -> return v
        is Number -> return v.toInt()
        is Enum<*> -> return enumOrdinalOrValue(v)
      }
    }
    return null
  }

  private fun invokeIntSource(target: Any, names: List<String>, value: Int) {
    for (name in names) {
      for (m in target.javaClass.methods) {
        if (m.name != name) continue
        val pts = m.parameterTypes
        val invoked = runCatching {
          when {
            pts.size == 1 && isIntType(pts[0]) -> {
              m.invoke(target, value)
              true
            }
            pts.size == 2 && isIntType(pts[0]) && isBoolType(pts[1]) -> {
              m.invoke(target, value, true)
              true
            }
            else -> false
          }
        }.getOrDefault(false)
        if (invoked) return
      }
    }
  }

  private fun isIntType(t: Class<*>): Boolean =
    t == Int::class.javaPrimitiveType || t == Integer::class.java || t == Integer.TYPE

  private fun isBoolType(t: Class<*>): Boolean =
    t == Boolean::class.javaPrimitiveType || t == java.lang.Boolean::class.java || t == java.lang.Boolean.TYPE

  private fun intConst(name: String): Int? {
    for (clsName in listOf(CLS_HCONSTANT, CLS_SOURCE_INFO, CLS_SOURCE_SERVICE, "android.carsource.McuConstant")) {
      val v = runCatching {
        val cls = Class.forName(clsName)
        val f = runCatching { cls.getField(name) }.getOrNull()
          ?: cls.declaredFields.firstOrNull { it.name == name }?.also { it.isAccessible = true }
          ?: return@runCatching null
        when {
          f.type == Int::class.javaPrimitiveType || f.type == Integer.TYPE -> f.getInt(null)
          f.type.isEnum -> enumOrdinalOrValue(f.get(null)!!)
          else -> null
        }
      }.getOrNull()
      if (v != null) return v
    }
    return null
  }

  private fun pathEnum(token: String): Any? {
    val cls = runCatching { Class.forName(CLS_SOURCE_PATH) }.getOrNull() ?: return null
    val constants = cls.enumConstants ?: return null
    val exact = constants.firstOrNull { it.toString() == "PATH_$token" || it.toString() == token }
    if (exact != null) return exact
    return constants.firstOrNull { name ->
      val n = name.toString()
      n.contains(token) && (token != "AUX" || !n.contains("AUX2"))
    }
  }

  private fun enumOrdinalOrValue(value: Any): Int {
    if (value is Enum<*>) {
      runCatching {
        val m = value.javaClass.methods.firstOrNull {
          it.name in listOf("getValue", "value", "getId") && it.parameterTypes.isEmpty()
        }
        val v = m?.invoke(value)
        if (v is Int) return v
        if (v is Number) return v.toInt()
      }
      return value.ordinal
    }
    if (value is Int) return value
    error("Not an enum/int: $value")
  }

  private fun singleton(cls: Class<*>, context: Context? = null): Any? {
    for (name in listOf("getInstance", "get", "getService", "getDefault")) {
      runCatching { return cls.getMethod(name).invoke(null) }
      if (context != null) {
        runCatching { return cls.getMethod(name, Context::class.java).invoke(null, context) }
      }
    }
    cls.declaredFields.forEach { f ->
      if (Modifier.isStatic(f.modifiers) && cls.isAssignableFrom(f.type)) {
        runCatching {
          f.isAccessible = true
          f.get(null)?.let { return it }
        }
      }
    }
    if (context != null) {
      runCatching { return cls.getConstructor(Context::class.java).newInstance(context) }
    }
    runCatching { return cls.getDeclaredConstructor().apply { isAccessible = true }.newInstance() }
    return null
  }

  private fun hConfigInt(key: String): Int? {
    val cfg = runCatching { singleton(Class.forName(CLS_HCONFIG)) }.getOrNull() ?: return null
    for (name in listOf("getInt", "getInteger")) {
      val m = cfg.javaClass.methods.firstOrNull {
        it.name == name && it.parameterTypes.size == 1 && it.parameterTypes[0] == String::class.java
      } ?: continue
      val v = runCatching { m.invoke(cfg, key) ?: m.invoke(cfg, key.substringAfter('/')) }.getOrNull()
      if (v is Int) return v
      if (v is Number) return v.toInt()
    }
    return null
  }

  private fun settingsInt(context: Context, key: String): Int? {
    return runCatching {
      Settings.System.getInt(context.contentResolver, key)
    }.getOrNull()
  }

  private fun hasPackage(context: Context, pkg: String): Boolean {
    return try {
      @Suppress("DEPRECATION")
      context.packageManager.getPackageInfo(pkg, 0)
      true
    } catch (_: PackageManager.NameNotFoundException) {
      false
    } catch (_: Throwable) {
      false
    }
  }

  private fun classExists(name: String): Boolean {
    return try {
      Class.forName(name)
      true
    } catch (_: Throwable) {
      false
    }
  }
}
