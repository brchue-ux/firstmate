package com.firstmate.autonomy.ui.decisions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.repository.DecisionRepository
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.asUiState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class DecisionListState(
    val decisions: List<Decision> = emptyList(),
    /** Ids of entries whose reflection is expanded. */
    val expandedIds: Set<Long> = emptySet(),
) {
    val isEmpty: Boolean get() = decisions.isEmpty()

    /** How often the choice made was the one wanted - the self-trust signal. */
    val ownPreferenceCount: Int get() = decisions.count { it.followedOwnPreference }

    val ownPreferencePercent: Int
        get() = if (decisions.isEmpty()) 0 else ownPreferenceCount * 100 / decisions.size

    /** Entries still waiting on an "outcome & how it felt" note. */
    val awaitingReflectionCount: Int get() = decisions.count { !it.hasReflection }
}

@HiltViewModel
class DecisionListViewModel @Inject constructor(
    private val decisionRepository: DecisionRepository,
) : ViewModel() {

    private val expandedIds = MutableStateFlow<Set<Long>>(emptySet())

    val uiState: StateFlow<UiState<DecisionListState>> =
        combine(decisionRepository.observeDecisions(), expandedIds) { decisions, expanded ->
            DecisionListState(decisions = decisions, expandedIds = expanded)
        }
            .asUiState("Could not load your decision log.")
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
                initialValue = UiState.Loading,
            )

    fun toggleExpanded(id: Long) {
        expandedIds.value = expandedIds.value.let { if (id in it) it - id else it + id }
    }

    fun deleteDecision(decision: Decision) {
        viewModelScope.launch { decisionRepository.deleteDecision(decision.id) }
    }

    private companion object {
        const val STOP_TIMEOUT_MILLIS = 5_000L
    }
}
