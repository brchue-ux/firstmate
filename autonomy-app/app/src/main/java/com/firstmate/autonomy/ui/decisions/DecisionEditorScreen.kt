package com.firstmate.autonomy.ui.decisions

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material3.Button
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.firstmate.autonomy.di.AutonomyViewModelFactory
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.ui.components.AutonomyMultilineField
import com.firstmate.autonomy.ui.components.AutonomyTextField
import com.firstmate.autonomy.ui.components.ChoiceChipRow
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.formatFull
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/** Create or edit one decision-log entry. */
@Composable
fun DecisionEditorScreen(
    onNavigateBack: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DecisionEditorViewModel = viewModel(factory = AutonomyViewModelFactory.Factory),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(uiState.isSaved) {
        if (uiState.isSaved) onNavigateBack()
    }

    DecisionEditorContent(
        uiState = uiState,
        onTitleChange = viewModel::onTitleChange,
        onDateChange = viewModel::onDateChange,
        onCategoryChange = viewModel::onCategoryChange,
        onMyPreferenceChange = viewModel::onMyPreferenceChange,
        onFinalChoiceChange = viewModel::onFinalChoiceChange,
        onReflectionChange = viewModel::onReflectionChange,
        onSave = viewModel::save,
        onNavigateBack = onNavigateBack,
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DecisionEditorContent(
    uiState: DecisionEditorUiState,
    onTitleChange: (String) -> Unit,
    onDateChange: (LocalDate) -> Unit,
    onCategoryChange: (DecisionCategory) -> Unit,
    onMyPreferenceChange: (String) -> Unit,
    onFinalChoiceChange: (String) -> Unit,
    onReflectionChange: (String) -> Unit,
    onSave: () -> Unit,
    onNavigateBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showDatePicker by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text(uiState.screenTitle) },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            AutonomyTextField(
                label = "Decision",
                value = uiState.title,
                onValueChange = onTitleChange,
                placeholder = "What was decided?",
                isError = uiState.showValidationErrors && uiState.titleError != null,
                supportingText = uiState.titleError.takeIf { uiState.showValidationErrors },
            )

            OutlinedButton(
                onClick = { showDatePicker = true },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Outlined.CalendarMonth, contentDescription = null)
                Text(
                    text = "  ${uiState.date.formatFull()}",
                    style = MaterialTheme.typography.labelLarge,
                )
            }

            ChoiceChipRow(
                label = "Category",
                options = DecisionCategory.entries,
                selected = uiState.category,
                onSelect = onCategoryChange,
                optionLabel = { it.label },
            )

            AutonomyMultilineField(
                label = "My preference",
                value = uiState.myPreference,
                onValueChange = onMyPreferenceChange,
                placeholder = "What did you actually want, before anyone weighed in?",
            )

            AutonomyMultilineField(
                label = "Final choice made",
                value = uiState.finalChoice,
                onValueChange = onFinalChoiceChange,
                placeholder = "What was decided in the end?",
            )

            AutonomyMultilineField(
                label = "Outcome & how it felt",
                value = uiState.reflection,
                onValueChange = onReflectionChange,
                placeholder = "Optional now - come back and fill this in once you know.",
                minLines = 4,
            )

            Button(onClick = onSave, modifier = Modifier.fillMaxWidth()) {
                Text(if (uiState.isEditing) "Save changes" else "Log decision")
            }
        }
    }

    if (showDatePicker) {
        DecisionDatePickerDialog(
            initialDate = uiState.date,
            onDateSelected = {
                onDateChange(it)
                showDatePicker = false
            },
            onDismiss = { showDatePicker = false },
        )
    }
}

/**
 * Material 3 date picker.
 *
 * Its state works in UTC epoch millis, so the conversion is pinned to
 * [ZoneOffset.UTC] in both directions - going through the device zone would
 * shift the date by a day near midnight.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DecisionDatePickerDialog(
    initialDate: LocalDate,
    onDateSelected: (LocalDate) -> Unit,
    onDismiss: () -> Unit,
) {
    val state = rememberDatePickerState(
        initialSelectedDateMillis = initialDate
            .atStartOfDay(ZoneOffset.UTC)
            .toInstant()
            .toEpochMilli(),
    )
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                onClick = {
                    val millis = state.selectedDateMillis
                    if (millis != null) {
                        onDateSelected(
                            Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate(),
                        )
                    } else {
                        onDismiss()
                    }
                },
            ) { Text("Select") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    ) {
        DatePicker(state = state)
    }
}

@ScreenPreviews
@Composable
private fun DecisionEditorPreview() {
    AutonomyTheme {
        val sample = PreviewData.decisions.first()
        DecisionEditorContent(
            uiState = DecisionEditorUiState(
                isEditing = true,
                title = sample.title,
                date = sample.date,
                category = sample.category,
                myPreference = sample.myPreference,
                finalChoice = sample.finalChoice,
                reflection = sample.reflection,
            ),
            onTitleChange = {},
            onDateChange = {},
            onCategoryChange = {},
            onMyPreferenceChange = {},
            onFinalChoiceChange = {},
            onReflectionChange = {},
            onSave = {},
            onNavigateBack = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DecisionEditorBlankPreview() {
    AutonomyTheme {
        DecisionEditorContent(
            uiState = DecisionEditorUiState(date = PreviewData.today),
            onTitleChange = {},
            onDateChange = {},
            onCategoryChange = {},
            onMyPreferenceChange = {},
            onFinalChoiceChange = {},
            onReflectionChange = {},
            onSave = {},
            onNavigateBack = {},
        )
    }
}
