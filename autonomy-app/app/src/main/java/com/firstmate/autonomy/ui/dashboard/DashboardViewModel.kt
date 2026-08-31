package com.firstmate.autonomy.ui.dashboard

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DashboardOverview
import com.firstmate.autonomy.domain.repository.HabitRepository
import com.firstmate.autonomy.domain.usecase.GetDashboardOverviewUseCase
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.asUiState
import dagger.hilt.android.lifecycle.HiltViewModel
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
import javax.inject.Inject

data class DashboardState(
    val today: LocalDate,
    val overview: DashboardOverview = DashboardOverview(),
) {
    /** Nothing anywhere in the app yet - the first-run welcome. */
    val isEmpty: Boolean get() = !overview.hasAnything
}

/** Read-mostly command centre; the only write it offers is today's check-in. */
@HiltViewModel
class DashboardViewModel @Inject constructor(
    getDashboardOverview: GetDashboardOverviewUseCase,
    private val habitRepository: HabitRepository,
    private val clock: Clock,
) : ViewModel() {

    private val today = MutableStateFlow(LocalDate.now(clock))

    @OptIn(ExperimentalCoroutinesApi::class)
    val uiState: StateFlow<UiState<DashboardState>> = combine(
        today.flatMapLatest { getDashboardOverview(it) },
        today,
    ) { overview, day ->
        DashboardState(today = day, overview = overview)
    }
        .asUiState("Could not load your dashboard.")
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
            initialValue = UiState.Loading,
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
