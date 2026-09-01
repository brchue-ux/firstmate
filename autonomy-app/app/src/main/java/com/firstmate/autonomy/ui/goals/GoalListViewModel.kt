package com.firstmate.autonomy.ui.goals

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.repository.GoalRepository
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
class GoalListViewModel @Inject constructor(
    private val goalRepository: GoalRepository,
    private val clock: Clock,
) : ViewModel() {

    val today: LocalDate get() = LocalDate.now(clock)

    val state: StateFlow<UiState<List<Goal>>> = goalRepository.observeGoals()
        .asUiState("Could not read your goals.")
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState.Loading)

    fun delete(goalId: Long) {
        viewModelScope.launch { goalRepository.deleteGoal(goalId) }
    }
}
