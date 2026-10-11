import {State,Center} from '../lib/model';
export type Action=(action:string,input:unknown)=>Promise<any>;
export type Props={state:State;center:Center;act:Action;busy:boolean};
export const dateTime=(s:string)=>new Date(s).toLocaleString('ko-KR',{timeZone:'Asia/Seoul',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
