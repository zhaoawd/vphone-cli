// Method-level execution for the JB orchestrator. Patch discovery still writes
// through; ablation must intercept run before setup or any method executes.
import Foundation

extension KernelJBPatcher: StructuredPatcher {
    /// Same 33 methods and order as findAll(), including every gated ablation target.
    public func buildSteps() -> [PatchStep] {
        [
            step("patchAmfiCdhashInTrustcache", .required, run: patchAmfiCdhashInTrustcache),
            step("patchTaskConversionEvalInternal", .required, run: patchTaskConversionEvalInternal),
            step("patchSandboxHooksExtended", .required, run: patchSandboxHooksExtended),
            step("patchIoucFailedMacf", .required, run: patchIoucFailedMacf),
            step("patchIoucFailedSandbox", .conditional(.iosBaseIs27), enabled: { [self] in applyIOS27 }, run: patchIoucFailedSandbox),
            step("patchDiskImages2ClientAbi", .conditional(.iosBaseIs27), enabled: { [self] in applyIOS27 }, run: patchDiskImages2ClientAbi),
            step("patchPostValidationAdditional", .required, run: patchPostValidationAdditional),
            step("patchProcSecurityPolicy", .required, run: patchProcSecurityPolicy),
            step("patchProcPidinfo", .required, run: patchProcPidinfo),
            step("patchConvertPortToMap", .required, run: patchConvertPortToMap),
            step("patchBsdInitAuth", .required, run: patchBsdInitAuth),
            step("patchDounmount", .required, run: patchDounmount),
            step("patchIoSecureBsdRoot", .required, run: patchIoSecureBsdRoot),
            step("patchLoadDylinker", .required, run: patchLoadDylinker),
            step("patchMacMount", .required, run: patchMacMount),
            step("patchNvramVerifyPermission", .required, run: patchNvramVerifyPermission),
            step("patchSharedRegionMap", .required, run: patchSharedRegionMap),
            step("patchSpawnValidatePersona", .required, run: patchSpawnValidatePersona),
            step("patchTaskForPid", .required, run: patchTaskForPid),
            step("patchThidShouldCrash", .required, run: patchThidShouldCrash),
            step("patchVmFaultEnterPrepare", .required, run: patchVmFaultEnterPrepare),
            step("patchVmMapProtect", .optional, run: patchVmMapProtect),
            step("patchThreadSetStateEntitlementFlag", .conditional(.cloudOSFridaCapable), enabled: { [self] in applyFrida }, run: patchThreadSetStateEntitlementFlag),
            step("patchVmMapDeleteImmutableCode", .conditional(.cloudOSFridaCapable), enabled: { [self] in applyFrida }, run: patchVmMapDeleteImmutableCode),
            step("patchCredLabelUpdateExecve", .optional, run: patchCredLabelUpdateExecve),
            step("patchHookCredLabelUpdateExecve", .required, run: patchHookCredLabelUpdateExecve),
            step("patchKcall10", .required, run: patchKcall10),
            step("patchSyscallmaskApplyToProc", .required, run: patchSyscallmaskApplyToProc),
            step("patchExecSecurityPolicyKill", .conditional(.iosBaseIs27), enabled: { [self] in applyIOS27 }, run: patchExecSecurityPolicyKill),
            step("patchContainerManagerUpcall", .conditional(.iosBaseIs27), enabled: { [self] in applyIOS27 }, run: patchContainerManagerUpcall),
            step("patchIomfbSwapEndVariableSize", .conditional(.iosBaseIs27), enabled: { [self] in applyIOS27 }, run: patchIomfbSwapEndVariableSize),
            step("patchIomfbSwapEndHandlerSize", .conditional(.iosBaseIs27), enabled: { [self] in applyIOS27 }, run: patchIomfbSwapEndHandlerSize),
            step("patchFpfsScopedVnodeOpen", .conditional(.iosBaseIs27), enabled: { [self] in applyIOS27 }, run: patchFpfsScopedVnodeOpen),
        ]
    }

    public var emittedRecords: [PatchRecord] { patches }
    public var patchedData: Data { buffer.data }

    public func commit(_ records: [PatchRecord]) {
        for record in records {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
    }

    private func step(
        _ method: String, _ requirement: PatchRequirement,
        enabled: @escaping () -> Bool = { true },
        run: @escaping () -> RawStepResult
    ) -> PatchStep {
        PatchStep(
            id: PatchID(component: "kernelcache", patcher: "KernelJBPatcher", method: method),
            requirement: requirement,
            run: { [self] in
                guard enabled() else { return .noMatch }
                ensurePrepared()
                return run()
            }
        )
    }
}
