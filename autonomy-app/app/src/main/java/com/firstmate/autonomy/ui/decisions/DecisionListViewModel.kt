package com.firstmate.autonomy.ui.decisions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.repository.DecisionRepository
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class DecisionListUiState(
    val isLoading: Boolean = true,
    val decisions: List<Decision> = emptyList(),
) {
    val isEmpty: Boolean get() = !isLoading && decisions.isEmpty()

    /** How often the choice made was the one wanted - the self-trust signal. */
    val ownPreferenceCount: Int get() = decisions.count { it.followedOwnPreference }

    val ownPreferencePercent: Int
        get() = if (decisions.isEmpty()) 0 else ownPreferenceCount * 100 / decisions.size

    /** Entries still waiting on an "outcome & how it felt" note. */
    val awaitingReflectionCount: Int get() = decisions.count { !it.hasReflection }
}

class DecisionListViewModel(
    private val decisionRepository: DecisionRepository,
) : ViewModel() {

    val uiState: StateFlow<DecisionListUiState> =
        decisionRepository.observeDecisions()
            .map { DecisionListUiState(isLoading = false, decisions = it) }
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
                initialValue = DecisionListUiState(),
            )

    fun deleteDecision(decision: Decision) {
        viewModelScope.launch { decisionRepository.deleteDecision(decision.id) }
    }

    private companion object {
        const val STOP_TIMEOUT_MILLIS = 5_000L
    }
}
