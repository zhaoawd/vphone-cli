export const originalSHA256 = 'c95fbf375e8ee3028e2399e3cf66f38eeacdf86e65e9da9175837994a3a076b1';
export const candidateSHA256 = 'f123428bb2bbede39df0cc1299b6324660e001a590f4fdf4075547ee3a18ca20';

export function validateTraceBaseline(state) {
    if (state.originalSHA256 !== originalSHA256) throw Error('Guest original library differs from the approved backup');
    if (state.candidateSHA256 !== candidateSHA256) throw Error('Unapproved diagnostic library');
    if (state.rootReadOnly !== true) throw Error('Expected the approved read-only guest baseline');
}

export function validateTraceBundle(hash) {
    if (hash !== originalSHA256) throw Error('Bundle auto-sync would replace the guest original before backup');
}
