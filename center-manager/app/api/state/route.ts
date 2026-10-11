import {read,mutate} from '../../../services/demo/store';
import {demoOwner,sameOrigin} from '../../../services/demo/auth';
export async function GET(){try{return Response.json(await read(await demoOwner()),{headers:{'Cache-Control':'no-store'}});}catch(e){console.error(e);return Response.json({error:'화면을 불러오지 못했습니다. 로그인 상태를 확인하고 다시 시도해 주세요.'},{status:503});}}
export async function POST(request:Request){try{sameOrigin(request);const owner=await demoOwner();if(Number(request.headers.get('content-length'))>20000)throw Error('입력 내용이 너무 큽니다.');const {action,input}=await request.json() as {action:string;input:unknown};return Response.json(await mutate(owner,action,input));}catch(e){const message=e instanceof Error?e.message:'저장하지 못했습니다.';return Response.json({error:message.startsWith('[')?'입력 내용을 확인해 주세요.':message},{status:400});}}

