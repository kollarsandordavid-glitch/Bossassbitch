const std = @import("std");
const protocol = @import("modal_protocol");

pub const CurriculumStageId = enum(u8) {
    broad_web_link_prediction = 1,
    general_query_doc_contrastive = 2,
    hard_negative_refinement = 3,
    structural_doc_and_paragraph = 4,
    code_search_specialization = 5,
    executive_profile_specialization = 6,
    research_scientific_specialization = 7,
    domain_adaptation_and_calibration = 8,
};

pub const CurriculumStageSpec = struct {
    stage: CurriculumStageId,
    name: []const u8,
    min_steps: u64,
    max_steps: u64,
    base_lr: f32,
    min_validation_recall_permille: u16,
};

pub const CURRICULUM_STAGES = [8]CurriculumStageSpec{
    .{ .stage = .broad_web_link_prediction, .name = "broad_web_link_prediction", .min_steps = 1000, .max_steps = 100000, .base_lr = 2.0e-4, .min_validation_recall_permille = 720 },
    .{ .stage = .general_query_doc_contrastive, .name = "general_query_doc_contrastive", .min_steps = 1000, .max_steps = 100000, .base_lr = 1.5e-4, .min_validation_recall_permille = 780 },
    .{ .stage = .hard_negative_refinement, .name = "hard_negative_refinement", .min_steps = 500, .max_steps = 60000, .base_lr = 1.0e-4, .min_validation_recall_permille = 830 },
    .{ .stage = .structural_doc_and_paragraph, .name = "structural_doc_and_paragraph", .min_steps = 500, .max_steps = 50000, .base_lr = 8.0e-5, .min_validation_recall_permille = 850 },
    .{ .stage = .code_search_specialization, .name = "code_search_specialization", .min_steps = 500, .max_steps = 50000, .base_lr = 6.0e-5, .min_validation_recall_permille = 870 },
    .{ .stage = .executive_profile_specialization, .name = "executive_profile_specialization", .min_steps = 400, .max_steps = 40000, .base_lr = 5.0e-5, .min_validation_recall_permille = 885 },
    .{ .stage = .research_scientific_specialization, .name = "research_scientific_specialization", .min_steps = 500, .max_steps = 50000, .base_lr = 4.5e-5, .min_validation_recall_permille = 900 },
    .{ .stage = .domain_adaptation_and_calibration, .name = "domain_adaptation_and_calibration", .min_steps = 400, .max_steps = 50000, .base_lr = 2.5e-5, .min_validation_recall_permille = 920 },
};

pub const CurriculumController = struct {
    current_stage: CurriculumStageId,
    stage_step: u64,
    global_step: u64,
    active_hardware_budget: protocol.HardwareBudget,
    reference_h200_budget: protocol.HardwareBudget,

    pub fn init(detected_b300_gpus: u32, target_global_batch: u32) CurriculumController {
        return .{
            .current_stage = .broad_web_link_prediction,
            .stage_step = 0,
            .global_step = 0,
            .active_hardware_budget = protocol.HardwareBudget.computeForProfile(
                .nvidia_b300_modal,
                detected_b300_gpus,
                target_global_batch,
            ),
            .reference_h200_budget = protocol.HardwareBudget.computeForProfile(
                .nvidia_h200_reference_144,
                144,
                target_global_batch,
            ),
        };
    }

    pub fn currentSpec(self: CurriculumController) CurriculumStageSpec {
        const idx: usize = @intFromEnum(self.current_stage) - 1;
        return CURRICULUM_STAGES[idx];
    }

    pub fn advanceStepAndCheckTransition(
        self: *CurriculumController,
        validation_recall_permille: u16,
    ) bool {
        self.stage_step += 1;
        self.global_step += 1;
        const spec = self.currentSpec();
        if (self.stage_step >= spec.min_steps and validation_recall_permille >= spec.min_validation_recall_permille) {
            if (@intFromEnum(self.current_stage) < 8) {
                self.current_stage = @enumFromInt(@intFromEnum(self.current_stage) + 1);
                self.stage_step = 0;
                return true;
            }
        }
        return false;
    }
};
