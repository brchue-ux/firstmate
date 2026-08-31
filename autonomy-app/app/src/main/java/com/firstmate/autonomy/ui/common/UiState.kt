package com.firstmate.autonomy.ui.common

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart

/**
 * The single state shape every screen renders.
 *
 * Modelling it as a sealed interface rather than a data class of nullable
 * fields is what prevents a partial render: there is no way to express
 * "loading finished but the data is still null", so a screen cannot
 * accidentally draw an empty list while the first query is still in flight.
 * The compiler forces every screen to answer all three cases.
 */
sealed interface UiState<out T> {

    /** No data yet. The first frame from a local database is fast but not free. */
    data object Loading : UiState<Nothing>

    data class Success<out T>(val data: T) : UiState<T>

    /**
     * A read failed. [message] is user-facing; [cause] is kept for logging and
     * is never shown.
     */
    data class Error(
        val message: String,
        val cause: Throwable? = null,
    ) : UiState<Nothing>

    val dataOrNull: T?
        get() = (this as? Success)?.data
}

/**
 * Lifts a cold data flow into [UiState]: Loading until the first emission,
 * Success per emission, and Error if the source throws.
 *
 * The `catch` is what makes an unreadable database a rendered message rather
 * than a crash - a corrupted file or a failed migration surfaces in the UI
 * instead of taking the process down.
 */
fun <T> Flow<T>.asUiState(
    errorMessage: String = "Something went wrong reading your data.",
): Flow<UiState<T>> = this
    .map<T, UiState<T>> { UiState.Success(it) }
    .onStart { emit(UiState.Loading) }
    .catch { throwable -> emit(UiState.Error(errorMessage, throwable)) }
