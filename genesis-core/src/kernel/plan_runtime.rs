use crate::audit::{AuditEvent, AuditLogger, PlanStep, VerificationResult};

use super::PlanDraftEnvelope;

pub(super) struct PlanRuntime {
    active_plan: Option<ActivePlan>,
}

struct ActivePlan {
    plan_id: String,
    steps: Vec<PlanStep>,
    current_index: usize,
    awaiting_action_id: Option<String>,
}

impl PlanRuntime {
    pub(super) fn new() -> Self {
        Self { active_plan: None }
    }

    pub(super) fn active_plan_id(&self) -> Option<String> {
        self.active_plan.as_ref().map(|plan| plan.plan_id.clone())
    }

    pub(super) fn active_plan_step_index(&self) -> Option<u32> {
        self.active_plan
            .as_ref()
            .and_then(|plan| plan.steps.get(plan.current_index))
            .map(|step| step.step_index)
    }

    pub(super) fn is_awaiting_action(&self) -> bool {
        self.active_plan
            .as_ref()
            .is_some_and(|plan| plan.awaiting_action_id.is_some())
    }

    pub(super) fn allows_plan_draft(&self) -> bool {
        self.active_plan.is_none()
    }

    pub(super) fn allows_action_dispatch(&self) -> bool {
        self.active_plan
            .as_ref()
            .is_none_or(|plan| plan.awaiting_action_id.is_none())
    }

    pub(super) fn active_step_payload(&self) -> Option<serde_json::Value> {
        let plan = self.active_plan.as_ref()?;
        if plan.awaiting_action_id.is_some() {
            return None;
        }
        let step = plan.steps.get(plan.current_index)?;
        Some(serde_json::json!({
            "plan_id": plan.plan_id,
            "step_index": step.step_index,
            "intent": step.intent,
            "target_selector": step.target_selector,
        }))
    }

    pub(super) fn activate_plan(
        &mut self,
        tick_id: u64,
        plan: PlanDraftEnvelope,
        auditor: &AuditLogger,
    ) {
        if plan.steps.is_empty() {
            auditor.log(AuditEvent::FailureObserved {
                tick_id,
                component: "PlannerDecoder".to_string(),
                error: format!("empty plan ignored: {}", plan.plan_id),
            });
            return;
        }

        println!(
            "[Planner] 🧭 Tick {} activated plan {} source Tick {} goal={} steps={}",
            tick_id,
            plan.plan_id,
            plan.tick,
            plan.goal,
            plan.steps.len()
        );
        auditor.log(AuditEvent::PlanDrafted {
            tick_id,
            source_tick_id: plan.tick,
            plan_id: plan.plan_id.clone(),
            goal: plan.goal,
            steps: plan.steps.clone(),
        });
        self.active_plan = Some(ActivePlan {
            plan_id: plan.plan_id.clone(),
            steps: plan.steps,
            current_index: 0,
            awaiting_action_id: None,
        });
        auditor.log(AuditEvent::PlanActivated {
            tick_id,
            plan_id: plan.plan_id,
        });
        self.log_current_step(tick_id, auditor);
    }

    pub(super) fn apply_verification(
        &mut self,
        tick_id: u64,
        result: &VerificationResult,
        auditor: &AuditLogger,
    ) {
        let Some(plan) = self.active_plan.as_ref() else {
            return;
        };
        let plan_id = plan.plan_id.clone();
        let from_step = plan.current_index as u32;

        match result {
            VerificationResult::Verified => {
                let next_index = plan.current_index + 1;
                auditor.log(AuditEvent::PlanAdvanced {
                    tick_id,
                    plan_id: plan_id.clone(),
                    from_step,
                    to_step: next_index as u32,
                });

                if next_index >= plan.steps.len() {
                    self.active_plan = None;
                    return;
                }

                if let Some(plan) = self.active_plan.as_mut() {
                    plan.current_index = next_index;
                    plan.awaiting_action_id = None;
                }
                self.log_current_step(tick_id, auditor);
            }
            VerificationResult::Failed { reason } => {
                auditor.log(AuditEvent::PlanAborted {
                    tick_id,
                    plan_id,
                    at_step: from_step,
                    reason: reason.clone(),
                });
                self.active_plan = None;
            }
            VerificationResult::Timeout => {
                auditor.log(AuditEvent::PlanAborted {
                    tick_id,
                    plan_id,
                    at_step: from_step,
                    reason: "verification_timeout".to_string(),
                });
                self.active_plan = None;
            }
        }
    }

    pub(super) fn bind_action(&mut self, action_id: String) {
        let Some(plan) = self.active_plan.as_mut() else {
            return;
        };
        if plan.awaiting_action_id.is_none() {
            plan.awaiting_action_id = Some(action_id);
        }
    }

    pub(super) fn action_matches_step(&self, action_id: &str) -> bool {
        self.active_plan
            .as_ref()
            .and_then(|plan| plan.awaiting_action_id.as_deref())
            == Some(action_id)
    }

    fn log_current_step(&self, tick_id: u64, auditor: &AuditLogger) {
        let Some(plan) = self.active_plan.as_ref() else {
            return;
        };
        let Some(step) = plan.steps.get(plan.current_index) else {
            // Plan has no steps left — emit final StepActivated
            auditor.log(AuditEvent::StepActivated {
                tick_id,
                plan_id: plan.plan_id.clone(),
                step_index: 0,
                intent: "<plan_complete>".to_string(),
            });
            return;
        };

        let awaiting = plan.awaiting_action_id.is_some();
        eprintln!(
            "[Plan] 📋 Step {} activated: id={} index={} intent={} awaiting_action={}",
            tick_id, plan.plan_id, step.step_index, step.intent, awaiting,
        );
        auditor.log(AuditEvent::StepActivated {
            tick_id,
            plan_id: plan.plan_id.clone(),
            step_index: step.step_index,
            intent: step.intent.clone(),
        });
    }
}
