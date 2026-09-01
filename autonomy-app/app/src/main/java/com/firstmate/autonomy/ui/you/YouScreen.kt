package com.firstmate.autonomy.ui.you

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.data.preferences.SettingsRepository
import com.firstmate.autonomy.domain.repository.GoalRepository
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.SectionHeader
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.LocalDate
import javax.inject.Inject

/** What the You tab shows: a few honest totals, and the one preference there is. */
data class YouState(
    val goals: Int = 0,
    val particulars: Int = 0,
    val moments: Int = 0,
    val daysLoggedThisQuarter: Int = 0,
)

@HiltViewModel
class YouViewModel @Inject constructor(
    goalRepository: GoalRepository,
    private val settings: SettingsRepository,
    clock: Clock,
) : ViewModel() {

    val state: StateFlow<YouState> = goalRepository.observeGoals()
        .map { goals ->
            val today = LocalDate.now(clock)
            YouState(
                goals = goals.size,
                particulars = goals.sumOf { it.particulars.size },
                moments = goals.sumOf { it.momentCount },
                daysLoggedThisQuarter = goals
                    .flatMap { it.particulars }
                    .flatMap { it.checkInDays }
                    .filter { !it.isBefore(today.minusDays(89)) }
                    .distinct()
                    .size,
            )
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), YouState())

    val celebrationsEnabled: StateFlow<Boolean> = settings.celebrationsEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), true)

    fun setCelebrations(enabled: Boolean) {
        viewModelScope.launch { settings.setCelebrationsEnabled(enabled) }
    }
}

@Composable
fun YouRoute(modifier: Modifier = Modifier, viewModel: YouViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val celebrations by viewModel.celebrationsEnabled.collectAsStateWithLifecycle()
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SectionHeader(title = "Where you are")
        AutonomyCard {
            Stat("Goals", state.goals.toString())
            Stat("Particulars", state.particulars.toString())
            Stat("Moments named", state.moments.toString())
            Stat("Days logged, last 90", state.daysLoggedThisQuarter.toString())
        }
        SectionHeader(title = "Preferences")
        AutonomyCard {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(Modifier.padding(end = 12.dp)) {
                    Text("Celebrate", style = MaterialTheme.typography.titleSmall)
                    Text(
                        text = "A brief flourish when you finish something.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(checked = celebrations, onCheckedChange = viewModel::setCelebrations)
            }
        }
        Text(
            text = "Everything here stays on this phone. The app asks for no network " +
                "permission at all, so nothing it holds can leave.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.titleSmall)
    }
}
