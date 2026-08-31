package com.firstmate.autonomy.ui.domains

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.domain.repository.DomainRepository
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.asUiState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

/** Everything the project list renders once loading has succeeded. */
data class DomainListState(
    /** Already filtered; [totalCount] is the unfiltered size. */
    val domains: List<ProjectDomain> = emptyList(),
    val totalCount: Int = 0,
    /** null means "All". */
    val filter: DomainStatus? = null,
) {
    /** Nothing stored at all - show the first-run empty state. */
    val isEmpty: Boolean get() = totalCount == 0

    /** Projects exist, but the active filter hides every one of them. */
    val isFilteredEmpty: Boolean get() = totalCount > 0 && domains.isEmpty()

    val averageProgress: Float
        get() = if (domains.isEmpty()) 0f else domains.map { it.progress }.average().toFloat()
}

@HiltViewModel
class DomainListViewModel @Inject constructor(
    domainRepository: DomainRepository,
) : ViewModel() {

    private val filter = MutableStateFlow<DomainStatus?>(null)

    val uiState: StateFlow<UiState<DomainListState>> =
        combine(domainRepository.observeDomains(), filter) { domains, activeFilter ->
            DomainListState(
                domains = domains.filter { activeFilter == null || it.status == activeFilter },
                totalCount = domains.size,
                filter = activeFilter,
            )
        }
            .asUiState("Could not load your projects.")
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
                initialValue = UiState.Loading,
            )

    fun setFilter(status: DomainStatus?) {
        filter.value = status
    }

    private companion object {
        const val STOP_TIMEOUT_MILLIS = 5_000L
    }
}
