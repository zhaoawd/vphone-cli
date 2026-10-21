export async function run(cua,nodeRepl,{caseName,running}) {
  const fs=await import('node:fs/promises');
  const root='/Users/kolar/github/vphone-cli';
  const out=root+'/research/upstream_integration_2026-10-15/evidence/T51-runtime-20261021/authorized-boots';
  await fs.mkdir(out,{recursive:true});
  const app=await cua.getApp(root+'/.build/t51-runtime-launchpad-r2-20261021.app');
  const state=await app.getAXState({disableDiffing:true,emit:false});
  const row=state.match(/^\s*(\d+) row \([^\n]*\) target$/m);
  if(!row) throw Error('target row missing');
  await app.click(Number(row[1]));
  const snapshot=await app.getAXStateAndScreenshot({disableDiffing:true});
  await fs.writeFile(out+'/'+caseName+'.ax.txt',snapshot.state);
  if(snapshot.screenshot) await fs.writeFile(out+'/'+caseName+'.png',snapshot.screenshot);
  const hardware=snapshot.state.match(/^.*text CPU, Value: (.*)$/m)?.[1];
  if(!hardware) throw Error('hardware missing');
  const record=JSON.parse(await fs.readFile(root+'/.build/t51rt/lib/target/.vphone-runtime.json','utf8'));
  if(running) {
    if(!snapshot.state.includes('Value: 运行中') || !snapshot.state.includes('Help: '+record.instanceID)) throw Error('running instance differs');
    if(!hardware.includes('未知') || !hardware.includes('上次')) throw Error('running disk must have unknown exclusive usage and stale marker');
    if(!snapshot.state.includes('Description: 停止')) throw Error('stop action missing');
  } else {
    if(!snapshot.state.includes('Help: 已停止')) throw Error('target is not stopped');
    if(hardware.includes('未知') || hardware.includes('上次')) throw Error('stopped disk measurement is not current');
    if(!snapshot.state.includes('Description: 启动')) throw Error('start action missing');
  }
  const result={state:'passed',running,hardware,instanceID:record.instanceID,pid:record.pid,recordedAt:new Date().toISOString()};
  await fs.writeFile(out+'/'+caseName+'.json',JSON.stringify(result,null,2)+'\n');
  nodeRepl.write(result);
}
