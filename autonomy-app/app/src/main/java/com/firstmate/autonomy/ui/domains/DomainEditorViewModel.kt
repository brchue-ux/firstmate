package com.firstmate.autonomy.ui.domains

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.repository.DomainRepository
import com.firstmate.autonomy.ui.navigation.ARG_DOMAIN_ID
import com.firstmate.autonomy.ui.navigation.NO_ID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class DomainEditorUiState(
    val isEditing: Boolean = false,
    val isLoading: Boolean = false,
    val title: String = "",
    val category: String = "",
    val status: DomainStatus = DomainStatus.PLANNING,
    val notes: String = "",
    /** Only shown after the first save attempt, so the form is not hostile on open. */
    val showValidationErrors: Boolean = false,
    /** Flipped once the write completed; the screen pops on it. */
    val isSaved: Boolean = false,
) {
    val titleError: String? get() = if (title.isBlank()) "A title is required" else null
    val categoryError: String? get() = if (category.isBlank()) "A category is required" else null
    val isValid: Boolean get() = titleError == null && categoryError == null
    val screenTitle: String get() = if (isEditing) "Edit project" else "New project"
}

/** Backs both create and edit; the presence of a row id decides which. */
class DomainEditorViewModel(
    savedStateHandle: SavedStateHandle,
    private val domainRepository: DomainRepository,
) : ViewModel() {

    private val domainId: Long = savedStateHandle.get<Long>(ARG_DOMAIN_ID) ?: NO_ID
    private val isEditing = domainId != NO_ID

    private val _uiState = MutableStateFlow(
        DomainEditorUiState(isEditing = isEditing, isLoading = isEditing),
    )
    val uiState: StateFlow<DomainEditorUiState> = _uiState.asStateFlow()

    init {
        if (isEditing) loadExisting()
    }

    private fun loadExisting() = viewModelScope.launch {
        // A single snapshot: an open editor should not be overwritten under the
        // user's fingers by later database emissions.
        val existing = domainRepository.observeDomain(domainId).first()
        _uiState.update { state ->
            if (existing == null) {
                state.copy(isLoading = false)
            } else {
                state.copy(
                    isLoading = false,
                    title = existing.title,
                    category = existing.category,
                    status = existing.status,
                    notes = existing.notes,
                )
            }
        }
    }

    fun onTitleChange(value: String) = _uiState.update { it.copy(title = value) }

    fun onCategoryChange(value: String) = _uiState.update { it.copy(category = value) }

    fun onStatusChange(value: DomainStatus) = _uiState.update { it.copy(status = value) }

    fun onNotesChange(value: String) = _uiState.update { it.copy(notes = value) }

    fun save() {
        val state = _uiState.value
        if (!state.isValid) {
            _uiState.update { it.copy(showValidationErrors = true) }
            return
        }
        viewModelScope.launch {
            if (isEditing) {
                domainRepository.updateDomain(
                    id = domainId,
                    title = state.title,
                    category = state.category,
                    status = state.status,
                    notes = state.notes,
                )
            } else {
                domainRepository.createDomain(
                    title = state.title,
                    category = state.category,
                    status = state.status,
                    notes = state.notes,
                )
            }
            _uiState.update { it.copy(isSaved = true) }
        }
    }
}
