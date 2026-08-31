package com.firstmate.autonomy.ui.domains

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.domain.repository.DomainRepository
import com.firstmate.autonomy.ui.navigation.ARG_DOMAIN_ID
import com.firstmate.autonomy.ui.navigation.NO_ID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class DomainDetailUiState(
    val isLoading: Boolean = true,
    val domain: ProjectDomain? = null,
    /** Draft text of the "add milestone" field. */
    val newMilestoneTitle: String = "",
    /** Set once the project is gone, so the screen can pop itself. */
    val isDeleted: Boolean = false,
) {
    val canAddMilestone: Boolean get() = newMilestoneTitle.isNotBlank()
}

/**
 * Detail screen for one project: milestone checkboxes, notes and status.
 *
 * Every edit writes straight through to the database; the observed flow then
 * pushes the new state back, so there is no local copy to keep in sync.
 */
class DomainDetailViewModel(
    savedStateHandle: SavedStateHandle,
    private val domainRepository: DomainRepository,
) : ViewModel() {

    private val domainId: Long = savedStateHandle.get<Long>(ARG_DOMAIN_ID) ?: NO_ID

    private val newMilestoneTitle = MutableStateFlow("")
    private val deleted = MutableStateFlow(false)

    val uiState: StateFlow<DomainDetailUiState> = combine(
        domainRepository.observeDomain(domainId),
        newMilestoneTitle,
        deleted,
    ) { domain, draft, isDeleted ->
        DomainDetailUiState(
            isLoading = false,
            domain = domain,
            newMilestoneTitle = draft,
            isDeleted = isDeleted,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
        initialValue = DomainDetailUiState(),
    )

    fun onNewMilestoneTitleChange(value: String) {
        newMilestoneTitle.value = value
    }

    fun addMilestone() {
        val title = newMilestoneTitle.value.trim()
        if (title.isEmpty()) return
        newMilestoneTitle.value = ""
        viewModelScope.launch { domainRepository.addMilestone(domainId, title) }
    }

    fun setMilestoneCompleted(milestone: Milestone, isCompleted: Boolean) {
        viewModelScope.launch {
            domainRepository.setMilestoneCompleted(milestone.id, isCompleted)
        }
    }

    fun deleteMilestone(milestone: Milestone) {
        viewModelScope.launch { domainRepository.deleteMilestone(milestone) }
    }

    fun setStatus(status: DomainStatus) {
        val current = uiState.value.domain ?: return
        viewModelScope.launch {
            domainRepository.updateDomain(
                id = current.id,
                title = current.title,
                category = current.category,
                status = status,
                notes = current.notes,
            )
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
