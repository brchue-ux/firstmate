package com.firstmate.autonomy.ui.domains

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.domain.repository.DomainRepository
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.asUiState
import com.firstmate.autonomy.ui.navigation.ARG_DOMAIN_ID
import com.firstmate.autonomy.ui.navigation.NO_ID
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class DomainDetailState(
    val domain: ProjectDomain? = null,
    /** Draft text of the "add milestone" field. */
    val newMilestoneTitle: String = "",
    /** Set once the project is gone, so the screen can pop itself. */
    val isDeleted: Boolean = false,
    val notesExpanded: Boolean = true,
) {
    val canAddMilestone: Boolean get() = newMilestoneTitle.isNotBlank()
}

/** One-shot signals that must fire exactly once, never on recomposition. */
sealed interface DomainDetailEvent {
    /** The project just reached 100%. Confetti and haptics. */
    data object Completed : DomainDetailEvent

    /** A milestone was ticked but the project is not finished yet. */
    data object MilestoneTicked : DomainDetailEvent
}

@HiltViewModel
class DomainDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val domainRepository: DomainRepository,
) : ViewModel() {

    private val domainId: Long = savedStateHandle.get<Long>(ARG_DOMAIN_ID) ?: NO_ID

    private val newMilestoneTitle = MutableStateFlow("")
    private val deleted = MutableStateFlow(false)
    private val notesExpanded = MutableStateFlow(true)

    /**
     * A Channel rather than a StateFlow: a celebration is an event, and a
     * replayed state would re-fire the confetti on every rotation.
     */
    private val eventChannel = Channel<DomainDetailEvent>(Channel.BUFFERED)
    val events: Flow<DomainDetailEvent> = eventChannel.receiveAsFlow()

    val uiState: StateFlow<UiState<DomainDetailState>> = combine(
        domainRepository.observeDomain(domainId),
        newMilestoneTitle,
        deleted,
        notesExpanded,
    ) { domain, draft, isDeleted, expanded ->
        DomainDetailState(
            domain = domain,
            newMilestoneTitle = draft,
            isDeleted = isDeleted,
            notesExpanded = expanded,
        )
    }
        .asUiState("Could not load this project.")
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
            initialValue = UiState.Loading,
        )

    fun onNewMilestoneTitleChange(value: String) {
        newMilestoneTitle.value = value
    }

    fun toggleNotes() {
        notesExpanded.value = !notesExpanded.value
    }

    fun addMilestone() {
        val title = newMilestoneTitle.value.trim()
        if (title.isEmpty()) return
        newMilestoneTitle.value = ""
        viewModelScope.launch { domainRepository.addMilestone(domainId, title) }
    }

    /**
     * Ticking the last open milestone is the celebration trigger.
     *
     * The decision is made here, not in the UI: the screen would have to diff
     * two renders of the same list to notice, and would then fire again on any
     * recomposition that happened to observe the completed state.
     */
    fun setMilestoneCompleted(milestone: Milestone, isCompleted: Boolean) {
        viewModelScope.launch {
            domainRepository.setMilestoneCompleted(milestone.id, isCompleted)
            if (!isCompleted) return@launch

            val updated = domainRepository.observeDomain(domainId).first()
            val event = when {
                updated == null -> null
                updated.milestoneCount > 0 &&
                    updated.completedMilestoneCount == updated.milestoneCount ->
                    DomainDetailEvent.Completed
                else -> DomainDetailEvent.MilestoneTicked
            }
            event?.let { eventChannel.send(it) }
        }
    }

    fun deleteMilestone(milestone: Milestone) {
        viewModelScope.launch { domainRepository.deleteMilestone(milestone) }
    }

    fun setStatus(status: DomainStatus) {
        val current = uiState.value.dataOrNull?.domain ?: return
        viewModelScope.launch {
            domainRepository.updateDomain(
                id = current.id,
                title = current.title,
                category = current.category,
                status = status,
                notes = current.notes,
            )
            if (status == DomainStatus.COMPLETED && current.status != DomainStatus.COMPLETED) {
                eventChannel.send(DomainDetailEvent.Completed)
            }
        }
    }

    fun deleteDomain() {
        viewModelScope.launch {
            domainRepository.deleteDomain(domainId)
            deleted.value = true
        }
    }

    private companion object {
        const val STOP_TIMEOUT_MILLIS = 5_000L
    }
}
