package com.firstmate.autonomy.ui.dashboard

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DashboardOverview
import com.firstmate.autonomy.domain.repository.HabitRepository
import com.firstmate.autonomy.domain.usecase.GetDashboardOverviewUseCase
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.LocalDate

data class DashboardUiState(
    val isLoading: Boolean = true,
    val today: LocalDate = LocalDate.now(),
    val overview: DashboardOverview = DashboardOverview(),
) {
    /** Nothing anywhere in the app yet - the first-run welcome. */
    val isEmpty: Boolean get() = !isLoading && !overview.hasAnything
}

/** Read-mostly home screen; the only write it offers is today's habit check-in. */
class DashboardViewModel(
    getDashboardOverview: GetDashboardOverviewUseCase,
    private val habitRepository: HabitRepository,
    private val clock: Clock = Clock.systemDefaultZone(),
) : ViewModel() {

    private val today = MutableStateFlow(LocalDate.now(clock))

    @OptIn(ExperimentalCoroutinesApi::class)
    val uiState: StateFlow<DashboardUiState> = combine(
        today.flatMapLatest { getDashboardOverview(it) },
        today,
    ) { overview, day ->
        DashboardUiState(isLoading = false, today = day, overview = overview)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
        initialValue = DashboardUiState(today = LocalDate.now(clock)),
    )

    fun refreshToday() {
        today.value = LocalDate.now(clock)
    }

    fun setTodayCompleted(habitId: Long, isCompleted: Boolean) {
        viewModelScope.launch {
            habitRepository.setCheckIn(habitId, today.value, isCompleted)
        }
    }

    private companion object {
        const val STOP_TIMEOUT_MILLIS = 5_000L
    }
}
