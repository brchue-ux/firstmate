package com.firstmate.autonomy.ui.today

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.TodayOverview
import com.firstmate.autonomy.domain.repository.GoalRepository
import com.firstmate.autonomy.domain.usecase.GetTodayOverviewUseCase
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.asUiState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.LocalDate
import javax.inject.Inject

@HiltViewModel
class TodayViewModel @Inject constructor(
    getTodayOverview: GetTodayOverviewUseCase,
    private val goalRepository: GoalRepository,
    private val clock: Clock,
) : ViewModel() {

    val today: LocalDate get() = LocalDate.now(clock)

    val state: StateFlow<UiState<TodayOverview>> =
        getTodayOverview(LocalDate.now(clock))
            .asUiState("Could not read today.")
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState.Loading)

    fun setDone(particularId: Long, done: Boolean) {
        viewModelScope.launch {
            goalRepository.setCheckIn(particularId, LocalDate.now(clock), done)
        }
    }
}
