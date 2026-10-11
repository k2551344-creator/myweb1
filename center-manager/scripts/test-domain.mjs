import {spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
const out='.sites-runtime/test-build';mkdirSync(out,{recursive:true});
writeFileSync(out+'/package.json','{"type":"commonjs"}');
const compile=spawnSync(process.execPath,['node_modules/typescript/bin/tsc','lib/actions.ts','lib/seed.ts','--outDir',out,'--module','commonjs','--target','es2022','--esModuleInterop','--skipLibCheck','--strict'],{stdio:'inherit'});
if(compile.status!==0)process.exit(compile.status??1);
const test=spawnSync(process.execPath,['--test','tests/domain.cjs'],{stdio:'inherit'});process.exit(test.status??1);

