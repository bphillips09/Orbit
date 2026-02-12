package com.bp.orbit.headunit

import android.content.Context

/**
 * Interface for head-unit-specific native aux-in switching backends
 */
interface HeadUnitAuxBackend {
  /** Short stable identifier (returned to Flutter via getBackend) */
  val id: String

  /** Whether this backend is supported on the current device */
  fun isSupported(context: Context): Boolean

  /** Switch to aux-in and return whether aux input is active (or error) */
  fun switchToAuxBlocking(context: Context, timeoutMs: Long = 1500L): Result<Boolean>

  /** Whether the current input is aux-in (or error) */
  fun isCurrentInputAuxBlocking(context: Context, timeoutMs: Long = 1500L): Result<Boolean>
}

