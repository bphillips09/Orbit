package com.bp.orbit.headunit

import android.content.Context

/**
 * Backend selector/dispatcher for head unit native aux-in switching
 */
object HeadUnitAuxManager {
  private val backends: List<HeadUnitAuxBackend> = listOf(
    // FYT
    FytSyuMsAux,
    // PX5 / PX6 / Microntek
    MicrontekCarServiceAux,
    // JanCar / Autochips / Mediatek
    JancarAutochipsAux,
    // QF / MCU channel switch
    QfMcuAux,
    // Junsun V1
    JunsunMainAux,
    // Debug
    //DebugFakeAux,
  )

  fun getSupportedBackend(context: Context): HeadUnitAuxBackend? {
    val appContext = context.applicationContext
    for (b in backends) {
      try {
        if (b.isSupported(appContext)) return b
      } catch (_: Throwable) {
        // Ignore and keep searching
      }
    }
    return null
  }

  fun isSupported(context: Context): Boolean = getSupportedBackend(context) != null

  fun backendIdOrNull(context: Context): String? = getSupportedBackend(context)?.id

  fun switchToAuxBlocking(context: Context, timeoutMs: Long = 1500L): Result<Boolean> {
    val b = getSupportedBackend(context)
      ?: return Result.failure(UnsupportedOperationException("No supported head unit aux-in backend"))
    return b.switchToAuxBlocking(context, timeoutMs)
  }

  fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long = 1500L): Result<Boolean> {
    val b = getSupportedBackend(context)
      ?: return Result.failure(UnsupportedOperationException("No supported head unit aux-in backend"))
    return b.isCurrentInputAuxBlocking(context, timeoutMs)
  }

  fun exitAuxBlocking(context: Context, timeoutMs: Long = 1500L): Result<Boolean> {
    val b = getSupportedBackend(context)
      ?: return Result.failure(UnsupportedOperationException("No supported head unit aux-in backend"))
    return b.exitAuxBlocking(context, timeoutMs)
  }
}

