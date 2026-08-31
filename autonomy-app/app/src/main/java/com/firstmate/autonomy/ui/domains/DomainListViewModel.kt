package com.firstmate.autonomy.ui.domains

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.domain.repository.DomainRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

/** UI state for the project list, including the active status filter. */
data class DomainListUiState(
    val isLoading: Boolean = true,
    /** Already filtered; [totalCount] is the unfiltered size. */
    val domains: List<ProjectDomain> = emptyList(),
    val totalCount: Int = 0,
    /** null means "All". */
    val filter: DomainStatus? = null,
) {
    /** Nothing stored at all - show the first-run empty state. */
    val isEmpty: Boolean get() = !isLoading && totalCount == 0

    /** Projects exist, but the active filter hides every one of them. */
    val isFilteredEmpty: Boolean get() = !isLoading && totalCount > 0 && domains.isEmpty()
}

class DomainListViewModel(
    private val domainRepository: DomainRepository,
) : ViewModel() {

    private val filter = MutableStateFlow<DomainStatus?>(null)

    /** Kept separately so an empty filtered list can be told apart from an empty store. */
    private val allDomains = domainRepository.observeDomains()

    val uiState: StateFlow<DomainListUiState> =
        combine(allDomains, filter) { domains, activeFilter ->
            DomainListUiState(
                isLoading = false,
                domains = domains.filter { activeFilter == null || it.status == activeFilter },
                totalCount = domains.size,
                filter = activeFilter,
            )
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
            initialValue = DomainListUiState(),
        )

    fun setFilter(status: DomainStatus?) {
        filter.value = status
    }

    private companion object {
        const val STOP_TIMEOUT_MILLIS = 5_000L
    }
}
