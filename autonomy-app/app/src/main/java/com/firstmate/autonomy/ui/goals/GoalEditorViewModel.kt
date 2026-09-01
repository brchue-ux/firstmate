package com.firstmate.autonomy.ui.goals

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.SurfaceKind
import com.firstmate.autonomy.domain.repository.GoalRepository
import com.firstmate.autonomy.ui.navigation.ARG_GOAL_ID
import com.firstmate.autonomy.ui.navigation.NO_ID
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.LocalDate
import javax.inject.Inject

/** Editing form state for one goal, plus the particulars hanging off it. */
data class GoalEditorState(
    val goalId: Long = NO_ID,
    val title: String = "",
    val category: String = "",
    val notes: String = "",
    val status: GoalStatus = GoalStatus.ACTIVE,
    val goal: Goal? = null,
    val isLoading: Boolean = true,
    val isSaved: Boolean = false,
) {
    val isNew: Boolean get() = goalId == NO_ID
    val canSave: Boolean get() = title.isNotBlank()
}

@HiltViewModel
class GoalEditorViewModel @Inject constructor(
    private val goalRepository: GoalRepository,
    private val clock: Clock,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val goalId: Long = savedStateHandle.get<Long>(ARG_GOAL_ID) ?: NO_ID

    val today: LocalDate get() = LocalDate.now(clock)

    private val _state = MutableStateFlow(GoalEditorState(goalId = goalId))
    val state: StateFlow<GoalEditorState> = _state.asStateFlow()

    init {
        if (goalId == NO_ID) {
            _state.value = _state.value.copy(isLoading = false)
        } else {
            viewModelScope.launch {
                goalRepository.observeGoal(goalId).collect { goal ->
                    _state.value = _state.value.copy(
                        goal = goal,
                        title = if (_state.value.isLoading) goal?.title.orEmpty() else _state.value.title,
                        category = if (_state.value.isLoading) goal?.category.orEmpty() else _state.value.category,
                        notes = if (_state.value.isLoading) goal?.notes.orEmpty() else _state.value.notes,
                        status = if (_state.value.isLoading) goal?.status ?: GoalStatus.ACTIVE else _state.value.status,
                        isLoading = false,
                    )
                }
            }
        }
    }

    fun onTitleChange(value: String) { _state.value = _state.value.copy(title = value) }
    fun onCategoryChange(value: String) { _state.value = _state.value.copy(category = value) }
    fun onNotesChange(value: String) { _state.value = _state.value.copy(notes = value) }
    fun onStatusChange(value: GoalStatus) { _state.value = _state.value.copy(status = value) }

    fun save() {
        val current = _state.value
        if (!current.canSave) return
        viewModelScope.launch {
            if (current.isNew) {
                goalRepository.createGoal(current.title, current.category, current.notes)
            } else {
                goalRepository.updateGoal(
                    current.goalId, current.title, current.category, current.notes, current.status,
                )
            }
            _state.value = _state.value.copy(isSaved = true)
        }
    }

    fun addParticular(title: String, kind: SurfaceKind) {
        val current = _state.value
        if (title.isBlank() || current.isNew) return
        viewModelScope.launch {
            goalRepository.addParticular(current.goalId, title, kind, "")
        }
    }

    fun deleteParticular(particularId: Long) {
        viewModelScope.launch { goalRepository.deleteParticular(particularId) }
    }

    fun nameMoment(particularId: Long, label: String) {
        if (label.isBlank()) return
        viewModelScope.launch {
            goalRepository.addMoment(particularId, label, LocalDate.now(clock), "")
        }
    }

    fun deleteGoal(onDone: () -> Unit) {
        val current = _state.value
        if (current.isNew) { onDone(); return }
        viewModelScope.launch {
            goalRepository.deleteGoal(current.goalId)
            onDone()
        }
    }

    /** Reads the goal once, for callers that need it outside the stream. */
    suspend fun snapshot(): Goal? =
        if (goalId == NO_ID) null else goalRepository.observeGoal(goalId).first()
}
