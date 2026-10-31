// Submit only the explicitly approved, already selected host binding change.
export async function run(cua,nodeRepl) {
  const fs=await import('node:fs/promises');
  const root='/Users/kolar/github/vphone-cli';
  const output=root+'/.build/t52-real-20261021/gui-shutdown-fix/ui';
  const app=await cua.getApp(root+'/.build/t52-envfix-launchpad-20261022.app');
  const state=await app.getAXState({disableDiffing:true,emit:false});
  if(!state.includes('文本 Core Bundle 绑定') || !state.includes('Value: t52-v2 2.6.2-local.cd529f26a150')) throw Error('Wrong rebind target');
  if(!state.includes('弹出式按钮 核心 Bundle, Value: 2.6.2-local.af333c78ac3b')) throw Error('Wrong new version');
  if(!/转换 绑定后更新客户机环境, Value: off/.test(state)) throw Error('Guest update must remain off');
  const apply=state.match(/^\s*(\d+) 按钮 应用$/m);
  if(!apply)throw Error('Enabled Apply missing');
  await fs.writeFile(output+'/rebind-prepared-asserted.ax.txt',state);
  await app.click(Number(apply[1]));
  const observed=await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
  await fs.writeFile(output+'/rebind-submitted.ax.txt',observed.state);
  if(observed.screenshot)await fs.writeFile(output+'/rebind-submitted.png',observed.screenshot);
  await fs.writeFile(output+'/rebind-submitted.json',JSON.stringify({machine:'t52-v2',oldVersion:'2.6.2-local.cd529f26a150',newVersion:'2.6.2-local.af333c78ac3b',environmentUpdate:false,submittedAt:new Date().toISOString(),completionVerified:false},null,2)+'\n');
  nodeRepl.write(observed.state);
}
