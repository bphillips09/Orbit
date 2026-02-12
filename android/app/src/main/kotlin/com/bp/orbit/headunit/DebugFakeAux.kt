package com.bp.orbit.headunit

import android.content.Context
import android.content.pm.ApplicationInfo

/**
 * Debug-only fake backend
 */
object DebugFakeAux : HeadUnitAuxBackend {
  override val id: String = "debug_fake"

  private fun isDebuggable(context: Context): Boolean {
    return (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
  }

  override fun isSupported(context: Context): Boolean = isDebuggable(context)

  override fun switchToAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return if (isDebuggable(context)) {
      Result.success(true)
    } else {
      Result.failure(UnsupportedOperationException("DebugFakeAux is debug-only"))
    }
  }

  override fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long): Result<Boolean> {
    return if (isDebuggable(context)) {
      Result.success(true)
    } else {
      Result.failure(UnsupportedOperationException("DebugFakeAux is debug-only"))
    }
  }
}

