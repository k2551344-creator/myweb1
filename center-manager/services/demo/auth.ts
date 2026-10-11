import {getChatGPTUser} from '../../app/chatgpt-auth';
export async function demoOwner(){const user=await getChatGPTUser();if(user)return user.userId;if(process.env.NODE_ENV==='development')return 'local-demo';throw Error('로그인 후 다시 시도해 주세요.');}
export function sameOrigin(request:Request){const origin=request.headers.get('origin');if(!origin||origin!==new URL(request.url).origin)throw Error('허용하지 않는 요청입니다.');}
