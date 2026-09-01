package com.firstmate.autonomy.ui.space

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
class SpaceViewModel @Inject constructor(
    private val goalRepository: GoalRepository,
    private val clock: Clock,
) : ViewModel() {

    val today: LocalDate get() = LocalDate.now(clock)

    val state: StateFlow<UiState<List<Goal>>> = goalRepository.observeGoals()
        .asUiState("Could not read your goals.")
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState.Loading)

    /** Ticks today for one particular. Tapping again un-ticks it. */
    fun toggleToday(particularId: Long, done: Boolean) {
        viewModelScope.launch {
            goalRepository.setCheckIn(particularId, LocalDate.now(clock), done)
        }
    }

    fun nameMoment(particularId: Long, label: String) {
        if (label.isBlank()) return
        viewModelScope.launch {
            goalRepository.addMoment(particularId, label, LocalDate.now(clock), "")
        }
    }
}
