import {env} from 'cloudflare:workers';
import {State,normalize} from '../../lib/model';
import {seed} from '../../lib/seed';
import {applyAction} from '../../lib/actions';
const db=()=> (env as unknown as {DB:D1Database}).DB;
export async function read(owner:string){
 let row=await db().prepare('SELECT data,revision FROM demo_state WHERE owner=?').bind(owner).first<{data:string;revision:number}>();
 if(!row){await db().prepare('INSERT OR IGNORE INTO demo_state(owner,data,revision) VALUES(?,?,0)').bind(owner,JSON.stringify(seed())).run();row=await db().prepare('SELECT data,revision FROM demo_state WHERE owner=?').bind(owner).first<{data:string;revision:number}>();}
 if(!row)throw Error('테스트 데이터를 불러올 수 없습니다.');return {state:normalize(JSON.parse(row.data) as State),revision:row.revision};
}
export async function mutate(owner:string,action:string,input:unknown){
 for(let retry=0;retry<4;retry++){const {state,revision}=await read(owner);const result=applyAction(state,action,input);const saved=await db().prepare('UPDATE demo_state SET data=?,revision=revision+1 WHERE owner=? AND revision=?').bind(JSON.stringify(state),owner,revision).run();if(saved.meta.changes===1)return {state,result};}
 throw Error('다른 작업이 저장 중입니다. 잠시 후 다시 시도해 주세요.');
}

