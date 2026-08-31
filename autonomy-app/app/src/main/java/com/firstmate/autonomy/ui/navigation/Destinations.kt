package com.firstmate.autonomy.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Balance
import androidx.compose.material.icons.filled.Handyman
import androidx.compose.material.icons.filled.SpaceDashboard
import androidx.compose.material.icons.filled.TaskAlt
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material.icons.outlined.Handyman
import androidx.compose.material.icons.outlined.SpaceDashboard
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Every route in the app.
 *
 * Editor routes take an optional id: absent (or [NO_ID]) means "create new",
 * present means "edit that row". One route per editor keeps the ViewModel and
 * the back stack simple.
 */
object Routes {
    const val DASHBOARD = "dashboard"
    const val DOMAIN_LIST = "domains"
    const val DECISION_LIST = "decisions"
    const val HABITS = "habits"

    const val DOMAIN_DETAIL = "domains/{$ARG_DOMAIN_ID}"
    const val DOMAIN_EDITOR = "domain-editor?$ARG_DOMAIN_ID={$ARG_DOMAIN_ID}"
    const val DECISION_EDITOR = "decision-editor?$ARG_DECISION_ID={$ARG_DECISION_ID}"

    fun domainDetail(domainId: Long): String = "domains/$domainId"

    fun domainEditor(domainId: Long? = null): String =
        "domain-editor?$ARG_DOMAIN_ID=${domainId ?: NO_ID}"

    fun decisionEditor(decisionId: Long? = null): String =
        "decision-editor?$ARG_DECISION_ID=${decisionId ?: NO_ID}"
}

const val ARG_DOMAIN_ID = "domainId"
const val ARG_DECISION_ID = "decisionId"

/** Sentinel for "no row selected", i.e. the editor is in create mode. */
const val NO_ID = -1L

/** The four tabs of the bottom bar, in display order. */
enum class TopLevelDestination(
    val route: String,
    val label: String,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
) {
    DASHBOARD(
        route = Routes.DASHBOARD,
        label = "Home",
        selectedIcon = Icons.Filled.SpaceDashboard,
        unselectedIcon = Icons.Outlined.SpaceDashboard,
    ),
    DOMAINS(
        route = Routes.DOMAIN_LIST,
        label = "Domains",
        selectedIcon = Icons.Filled.Handyman,
        unselectedIcon = Icons.Outlined.Handyman,
    ),
    DECISIONS(
        route = Routes.DECISION_LIST,
        label = "Decisions",
        selectedIcon = Icons.Filled.Balance,
        unselectedIcon = Icons.Outlined.Balance,
    ),
    HABITS(
        route = Routes.HABITS,
        label = "Habits",
        selectedIcon = Icons.Filled.TaskAlt,
        unselectedIcon = Icons.Outlined.TaskAlt,
    ),
}
