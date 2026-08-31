package com.firstmate.autonomy.ui.decisions

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.repository.DecisionRepository
import com.firstmate.autonomy.ui.navigation.ARG_DECISION_ID
import com.firstmate.autonomy.ui.navigation.NO_ID
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import javax.inject.Inject

data class DecisionEditorUiState(
    val isEditing: Boolean = false,
    val isLoading: Boolean = false,
    val title: String = "",
    val date: LocalDate = LocalDate.now(),
    val category: DecisionCategory = DecisionCategory.PERSONAL,
    val myPreference: String = "",
    val finalChoice: String = "",
    val reflection: String = "",
    val showValidationErrors: Boolean = false,
    val isSaved: Boolean = false,
    /** Carried through an edit so an update never rewrites the creation time. */
    val createdAt: Instant = Instant.EPOCH,
) {
    val titleError: String? get() = if (title.isBlank()) "Give the decision a short name" else null
    val isValid: Boolean get() = titleError == null
    val screenTitle: String get() = if (isEditing) "Edit decision" else "Log a decision"
}

/**
 * Create or edit one journal entry.
 *
 * Reflection is intentionally optional: the entry is usually written at the
 * moment of deciding, and how it felt is only knowable later.
 */
@HiltViewModel
class DecisionEditorViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val decisionRepository: DecisionRepository,
    private val clock: Clock,
) : ViewModel() {

    private val decisionId: Long = savedStateHandle.get<Long>(ARG_DECISION_ID) ?: NO_ID
    private val isEditing = decisionId != NO_ID

    private val _uiState = MutableStateFlow(
        DecisionEditorUiState(
            isEditing = isEditing,
            isLoading = isEditing,
            date = LocalDate.now(clock),
        ),
    )
    val uiState: StateFlow<DecisionEditorUiState> = _uiState.asStateFlow()

    init {
        if (isEditing) loadExisting()
    }

    private fun loadExisting() = viewModelScope.launch {
        val existing = decisionRepository.observeDecision(decisionId).first()
        _uiState.update { state ->
            if (existing == null) {
                state.copy(isLoading = false)
            } else {
                state.copy(
                    isLoading = false,
                    title = existing.title,
                    date = existing.date,
                    category = existing.category,
                    myPreference = existing.myPreference,
                    finalChoice = existing.finalChoice,
                    reflection = existing.reflection,
                    createdAt = existing.createdAt,
                )
            }
        }
    }

    fun onTitleChange(value: String) = _uiState.update { it.copy(title = value) }

    fun onDateChange(value: LocalDate) = _uiState.update { it.copy(date = value) }

    fun onCategoryChange(value: DecisionCategory) = _uiState.update { it.copy(category = value) }

    fun onMyPreferenceChange(value: String) = _uiState.update { it.copy(myPreference = value) }

    fun onFinalChoiceChange(value: String) = _uiState.update { it.copy(finalChoice = value) }

    fun onReflectionChange(value: String) = _uiState.update { it.copy(reflection = value) }

    fun save() {
        val state = _uiState.value
        if (!state.isValid) {
            _uiState.update { it.copy(showValidationErrors = true) }
            return
        }
        viewModelScope.launch {
            if (isEditing) {
                decisionRepository.updateDecision(
                    Decision(
                        id = decisionId,
                        title = state.title,
                        date = state.date,
                        category = state.category,
                        myPreference = state.myPreference,
                        finalChoice = state.finalChoice,
                        reflection = state.reflection,
                        createdAt = state.createdAt,
                    ),
                )
            } else {
                decisionRepository.createDecision(
                    title = state.title,
                    date = state.date,
                    category = state.category,
                    myPreference = state.myPreference,
                    finalChoice = state.finalChoice,
                    reflection = state.reflection,
                )
            }
            _uiState.update { it.copy(isSaved = true) }
        }
    }
}
