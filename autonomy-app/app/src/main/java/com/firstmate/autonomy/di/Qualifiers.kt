package com.firstmate.autonomy.di

import javax.inject.Qualifier

/**
 * Marks the dispatcher used for disk work. Injecting it rather than reaching for
 * `Dispatchers.IO` directly is what makes repositories testable: a test swaps in
 * a deterministic dispatcher without touching production code.
 */
@Retention(AnnotationRetention.BINARY)
@Qualifier
annotation class IoDispatcher

/** The dispatcher for CPU-bound work. */
@Retention(AnnotationRetention.BINARY)
@Qualifier
annotation class DefaultDispatcher
