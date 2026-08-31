package com.firstmate.autonomy.ui.components

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/** Standard single-line text input used across both editors. */
@Composable
fun AutonomyTextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    supportingText: String? = null,
    isError: Boolean = false,
    singleLine: Boolean = true,
    minLines: Int = 1,
    imeAction: ImeAction = ImeAction.Next,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it) } },
        supportingText = supportingText?.let { { Text(it) } },
        isError = isError,
        singleLine = singleLine,
        minLines = minLines,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.Sentences,
            imeAction = imeAction,
        ),
    )
}

/** Multi-line input for notes, preferences and reflections. */
@Composable
fun AutonomyMultilineField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    minLines: Int = 3,
) {
    AutonomyTextField(
        label = label,
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.heightIn(min = 96.dp),
        placeholder = placeholder,
        singleLine = false,
        minLines = minLines,
        imeAction = ImeAction.Default,
    )
}

/**
 * Horizontal single-select chip row. Used for project status and decision
 * category, where the option set is short and always worth showing in full.
 */
@Composable
fun <T> ChoiceChipRow(
    label: String,
    options: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    optionLabel: (T) -> String,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(bottom = 8.dp),
        )
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            options.forEach { option ->
                FilterChip(
                    selected = option == selected,
                    onClick = { onSelect(option) },
                    label = { Text(optionLabel(option)) },
                )
            }
        }
    }
}

@ThemePreviews
@Composable
private fun FormFieldsPreview() {
    AutonomyTheme {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            AutonomyTextField(
                label = "Title",
                value = "Rewire the bench power supply",
                onValueChange = {},
            )
            AutonomyTextField(
                label = "Title",
                value = "",
                onValueChange = {},
                placeholder = "What are you building?",
                isError = true,
                supportingText = "A title is required",
            )
            ChoiceChipRow(
                label = "Status",
                options = listOf("Planning", "In Progress", "Completed"),
                selected = "In Progress",
                onSelect = {},
                optionLabel = { it },
            )
        }
    }
}
