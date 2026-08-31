package com.firstmate.autonomy.ui.habits

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.firstmate.autonomy.domain.model.DayStatus
import com.firstmate.autonomy.domain.model.HabitConsistency
import com.firstmate.autonomy.domain.repository.HabitRepository
import com.firstmate.autonomy.domain.usecase.GetHabitConsistencyUseCase
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.LocalDate

/** Draft state of the "new habit" dialog. */
data class NewHabitDraft(
    val isVisible: Boolean = false,
    val name: String = "",
    val description: String = "",
) {
    val canSave: Boolean get() = name.isNotBlank()
}

data class HabitUiState(
    val isLoading: Boolean = true,
    val today: LocalDate = LocalDate.now(),
    /** One entry per habit, each carrying a [MONTH_DAYS]-day series. */
    val habits: List<HabitConsistency> = emptyList(),
    val newHabit: NewHabitDraft = NewHabitDraft(),
) {
    val isEmpty: Boolean get() = !isLoading && habits.isEmpty()

    val completedToday: Int
        get() = habits.count { it.days.lastOrNull()?.isCompleted == true }

    val todayProgress: Float
        get() = if (habits.isEmpty()) 0f else completedToday.toFloat() / habits.size

    /** Completion across every habit-day this month, not an average of averages. */
    val monthlyRatePercent: Int
        get() {
            val total = habits.sumOf { it.days.size }
            if (total == 0) return 0
            return habits.sumOf { it.completedCount } * 100 / total
        }

    companion object {
        const val MONTH_DAYS = 30
        const val WEEK_DAYS = 7
    }
}

/** The last seven days of a month-long series - what the weekly strip draws. */
fun HabitConsistency.thisWeek(): List<DayStatus> =
    days.takeLast(HabitUiState.WEEK_DAYS)

/**
 * Daily check-in plus weekly and monthly consistency.
 *
 * A single 30-day query backs both views: the weekly strip is just its tail,
 * so ticking a box updates every figure on screen from one emission.
 */
class HabitViewModel(
    private val habitRepository: HabitRepository,
    getHabitConsistency: GetHabitConsistencyUseCase,
    private val clock: Clock = Clock.systemDefaultZone(),
) : ViewModel() {

    /**
     * Today, re-read on [refreshToday] rather than cached forever, so a screen
     * left open across midnight starts writing to the new day.
     */
    private val today = MutableStateFlow(LocalDate.now(clock))

    private val newHabit = MutableStateFlow(NewHabitDraft())

    @OptIn(ExperimentalCoroutinesApi::class)
    val uiState: StateFlow<HabitUiState> = combine(
        today.flatMapLatest { day ->
            getHabitConsistency(today = day, windowDays = HabitUiState.MONTH_DAYS)
        },
        today,
        newHabit,
    ) { consistency, day, draft ->
        HabitUiState(
            isLoading = false,
            today = day,
            habits = consistency,
            newHabit = draft,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MILLIS),
        initialValue = HabitUiState(today = LocalDate.now(clock)),
    )

    /** Called when the screen resumes, so a stale "today" cannot mis-file a check-in. */
    fun refreshToday() {
        today.value = LocalDate.now(clock)
    }

    fun setTodayCompleted(habitId: Long, isCompleted: Boolean) {
        viewModelScope.launch {
            habitRepository.setCheckIn(habitId, today.value, isCompleted)
        }
    }

    fun showAddHabit() = newHabit.update { NewHabitDraft(isVisible = true) }

    fun dismissAddHabit() = newHabit.update { NewHabitDraft(isVisible = false) }

    fun onNewHabitNameChange(value: String) = newHabit.update { it.copy(name = value) }

    fun onNewHabitDescriptionChange(value: String) =
        newHabit.update { it.copy(description = value) }

    fun saveNewHabit() {
        val draft = newHabit.value
        if (!draft.canSave) return
        newHabit.value = NewHabitDraft(isVisible = false)
        viewModelScope.launch {
            habitRepository.createHabit(name = draft.name, description = draft.description)
        }
    }

    /** Archive rather than delete: the past month of history stays intact. */
    fun archiveHabit(habitId: Long) {
        viewModelScope.launch { habitRepository.archiveHabit(habitId) }
    }

    private companion object {
        const val STOP_TIMEOUT_MILLIS = 5_000L
    }
}
