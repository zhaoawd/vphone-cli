const defaultWork = '/Users/kolar/github/vphone-cli/.build/t52-real-20261021/gui-shutdown-fix';
const defaultVersion = '2.6.2-local.af333c78ac3b';

export async function run(cua,nodeRepl,{phase,work=defaultWork,version=defaultVersion}) {
  if (!['bound','running','stopped'].includes(phase)) throw Error('Unknown phase');
  const fs = await import('node:fs/promises');
  const root = '/Users/kolar/github/vphone-cli';
  await fs.mkdir(work+'/ui',{recursive:true});
  const app = await cua.getApp(root+'/.build/t52-envfix-launchpad-20261022.app');
  let state = await app.getAXState({disableDiffing:true,emit:false});
  const row = state.match(/^\s*(\d+) row \([^\n]*\) t52-v2$/m);
  if (!row) throw Error('Named independent VM row missing');
  await app.click(Number(row[1]));
  const observation = await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
  state = observation.state;
  const output = work+'/ui/default-gui-'+phase;
  await fs.writeFile(output+'.ax.txt',state);
  if (observation.screenshot) await fs.writeFile(output+'.png',observation.screenshot);
  if (!state.includes('Help: '+version)) throw Error('Selected host binding differs');
  const result = {state:'passed',phase,recordedAt:new Date().toISOString()};
  if (phase === 'running') {
    const runtime = JSON.parse(await fs.readFile(root+'/.build/t51rt/lib/t52-v2/.vphone-runtime.json','utf8'));
    if (!state.includes('运行中') || !state.includes('Help: '+runtime.instanceID)) throw Error('Running instance differs');
    if (!state.includes('Description: 停止')) throw Error('Stop action missing');
    result.instanceID=runtime.instanceID; result.pid=runtime.pid;
  } else {
    if (!state.includes('Help: 已停止') || !state.includes('Description: 启动')) throw Error('Stopped state or start action missing');
    if (state.includes('正在更新客户机环境') || state.includes('Core Bundle 绑定')) throw Error('Update UI still active');
  }
  await fs.writeFile(output+'.json',JSON.stringify(result,null,2)+'\n');
  nodeRepl.write(result);
}

export async function act(cua,nodeRepl,{action,work=defaultWork,version=defaultVersion}) {
  if (!['start','stop'].includes(action)) throw Error('Unknown action');
  const fs = await import('node:fs/promises');
  const root = '/Users/kolar/github/vphone-cli';
  await fs.mkdir(work+'/ui',{recursive:true});
  const app = await cua.getApp(root+'/.build/t52-envfix-launchpad-20261022.app');
  const state = await app.getAXState({disableDiffing:true,emit:false});
  if (!/row \(selected\) t52-v2/.test(state) || !state.includes('Help: '+version)) throw Error('Named bound VM must be selected');
  const label = action === 'start' ? '启动' : '停止';
  const button = state.match(new RegExp('^\\s*(\\d+) 按钮 Description: '+label+',','m'));
  if (!button) throw Error('Expected enabled VM action missing');
  await app.click(Number(button[1]));
  const observation = await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
  const output = work+'/ui/default-gui-'+action+'-submitted';
  await fs.writeFile(output+'.ax.txt',observation.state);
  if (observation.screenshot) await fs.writeFile(output+'.png',observation.screenshot);
  await fs.writeFile(output+'.json',JSON.stringify({action,machine:'t52-v2',submittedAt:new Date().toISOString(),completionVerified:false},null,2)+'\n');
  nodeRepl.write(observation.state);
}
