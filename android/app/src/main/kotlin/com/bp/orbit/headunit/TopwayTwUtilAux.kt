package com.bp.orbit.headunit

import android.content.Context

/**
 * Topway AUX-in switching via framework vendor API
 */
object TopwayTwUtilAux : HeadUnitAuxBackend {
  override val id: String = "topway_twutil"

  private const val CHANNEL_ID: Short = 517

  private const val CMD_MODE = 40448
  private const val MODE_ENTER = 7
  private const val MODE_EXIT = 135

  private const val CMD_ENTER = 769
  private const val CMD_EXIT = 40465
  private const val ARG_FIXED = 192

  private const val CMD_STATUS = 517
  private const val STATUS_POLL = 255

  private const val TWUTIL_CLASS = "android.tw.john.TWUtil"

  private val lock = Any()
  private var util: Any? = null
  private var opened: Boolean = false
  private var started: Boolean = false

  override fun isSupported(context: Context): Boolean {
    // Verify class exists
    return try {
      Class.forName(TWUTIL_CLASS)
      true
    } catch (_: Throwable) {
      false
    }
  }

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return runCatching {
      val u = ensureOpenAndStarted()

      // Enter Aux-in
      write2(u, CMD_MODE, MODE_ENTER)
      write3(u, CMD_ENTER, ARG_FIXED, MODE_ENTER)
      write2(u, CMD_STATUS, STATUS_POLL)

      true
    }
  }

  override fun exitAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return runCatching {
      val u = ensureOpenAndStarted()

      // Exit Aux-in
      write2(u, CMD_MODE, MODE_EXIT)
      write3(u, CMD_EXIT, ARG_FIXED, MODE_EXIT)

      // Release resources
      stopAndClose()
      true
    }
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    // Treat as unsupported for now
    return Result.failure(UnsupportedOperationException("Topway TWUtil does not expose current-input query"))
  }

  private fun ensureOpenAndStarted(): Any {
    synchronized(lock) {
      val u = util ?: newTwUtil().also { util = it }

      if (!opened) {
        val rc = invokeOpen(u, shortArrayOf(CHANNEL_ID), flag = 0)
        if (rc != 0) error("TWUtil.open([${CHANNEL_ID.toInt()}]) failed (rc=$rc)")
        opened = true
      }

      if (!started) {
        invokeNoArgs(u, "start")
        started = true
      }

      return u
    }
  }

  private fun stopAndClose() {
    synchronized(lock) {
      val u = util ?: return
      try {
        if (started) invokeNoArgs(u, "stop")
      } catch (_: Throwable) {
      }
      try {
        if (opened) invokeNoArgs(u, "close")
      } catch (_: Throwable) {
      }
      started = false
      opened = false
      util = null
    }
  }

  private fun newTwUtil(): Any {
    val cls = resolveTwUtilClass()
    val ctor = cls.getConstructor()
    return ctor.newInstance()
  }

  private fun resolveTwUtilClass(): Class<*> {
    return Class.forName(TWUTIL_CLASS)
  }

  private fun invokeOpen(u: Any, ids: ShortArray, flag: Int): Int {
    val cls = u.javaClass
    // Prefer open(short[], int) if present, else open(short[])
    return try {
      val m = cls.getMethod("open", ShortArray::class.java, Int::class.javaPrimitiveType)
      (m.invoke(u, ids, flag) as Number).toInt()
    } catch (_: NoSuchMethodException) {
      val m2 = cls.getMethod("open", ShortArray::class.java)
      (m2.invoke(u, ids) as Number).toInt()
    }
  }

  private fun write2(u: Any, what: Int, arg1: Int): Int {
    val cls = u.javaClass
    val m = cls.getMethod("write", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
    val rc = (m.invoke(u, what, arg1) as Number).toInt()
    if (rc < 0) error("TWUtil.write($what,$arg1) failed (rc=$rc)")
    return rc
  }

  private fun write3(u: Any, what: Int, arg1: Int, arg2: Int): Int {
    val cls = u.javaClass
    val m = cls.getMethod(
      "write",
      Int::class.javaPrimitiveType,
      Int::class.javaPrimitiveType,
      Int::class.javaPrimitiveType
    )
    val rc = (m.invoke(u, what, arg1, arg2) as Number).toInt()
    if (rc < 0) error("TWUtil.write($what,$arg1,$arg2) failed (rc=$rc)")
    return rc
  }

  private fun invokeNoArgs(u: Any, name: String) {
    val m = u.javaClass.getMethod(name)
    m.invoke(u)
  }
}

