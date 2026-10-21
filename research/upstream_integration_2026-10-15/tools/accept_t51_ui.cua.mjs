export async function run(cua, nodeRepl, {acceptanceCase, expectedRunState, expectedCurrent, appPath}) {
// Execute through cua_repl after initialization. Every UI observation uses cua.
// Parameters supplied by the caller: acceptanceCase, expectedRunState, expectedCurrent.
var fsAcceptance = await import('node:fs/promises');
var acceptanceDirectory = '/Users/kolar/github/vphone-cli/research/upstream_integration_2026-10-15/evidence/T51-runtime-20261021';
var acceptanceApp = await cua.getApp(appPath || '/Users/kolar/github/vphone-cli/.build/t51-runtime-launchpad-r2-20261021.app');
var acceptanceState = await acceptanceApp.getAXState({disableDiffing:true,emit:false});
var acceptanceRow = acceptanceState.match(/^\s*(\d+) row \([^\n]*\) target$/m);
if (!acceptanceRow) throw new Error('target row missing');
await acceptanceApp.click(Number(acceptanceRow[1]));
var acceptanceSnapshot = await acceptanceApp.getAXStateAndScreenshot({disableDiffing:true});
var acceptanceHardware = acceptanceSnapshot.state.match(/^.*text CPU, Value: (.*)$/m)?.[1];
await fsAcceptance.writeFile(acceptanceDirectory+'/'+acceptanceCase+'.ax.txt',acceptanceSnapshot.state);
if(acceptanceSnapshot.screenshot) await fsAcceptance.writeFile(acceptanceDirectory+'/'+acceptanceCase+'.png',acceptanceSnapshot.screenshot);
if (!acceptanceHardware) throw new Error('hardware usage missing');
if (!acceptanceSnapshot.state.includes('Help: '+expectedRunState)) throw new Error('unexpected run state');
if (expectedCurrent && (acceptanceHardware.includes('未知') || acceptanceHardware.includes('上次'))) throw new Error('usage is not current');
if (!expectedCurrent && !acceptanceHardware.includes('未知')) throw new Error('exclusive usage must be unknown');
if (!acceptanceSnapshot.state.includes('419d5a6c67ab')) throw new Error('candidate identity differs');
await fsAcceptance.writeFile(acceptanceDirectory+'/'+acceptanceCase+'.ax.txt',acceptanceSnapshot.state);
if(acceptanceSnapshot.screenshot) await fsAcceptance.writeFile(acceptanceDirectory+'/'+acceptanceCase+'.png',acceptanceSnapshot.screenshot);
await fsAcceptance.writeFile(acceptanceDirectory+'/'+acceptanceCase+'.json',JSON.stringify({state:'passed',hardware:acceptanceHardware,expectedRunState,expectedCurrent,recordedAt:new Date().toISOString()},null,2)+'\n');
nodeRepl.write({case:acceptanceCase,state:'passed',hardware:acceptanceHardware});

}
