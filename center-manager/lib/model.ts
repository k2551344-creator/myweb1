export type Center = {businessName?:string; representative?:string; businessAddress?:string; businessPhone?:string; id:string; name:string; brand:string; address:string; phone:string; active:boolean; bgColor:string; bgImage:string; headline:string; overlay:number};
export type Product = {details?:string; terms?:string; cancellationNotice?:string; intervalUnit?:"week"|"month"; intervalCount?:number; revision?:number; id:string; centerId:string; name:string; description:string; category:string; price:number; recurring:boolean; weeklyLimit:number; capacity:number; stock:number; active:boolean; selling:boolean; sort:number; image:string; accessCenters:string[]};
export type Member = {id:string; name:string; phone:string; joinedAt:string};
export type Subscription = {id:string; memberId:string; centerId:string; productId:string; status:'ACTIVE'|'CANCEL_AT_PERIOD_END'|'EXPIRED'|'PAYMENT_FAILED'|'SUSPENDED'; price:number; lockerPrice:number; weeklyLimit:number; accessCenters:string[]; start:string; end:string; nextPayment:string; createdAt:string; lockerId:string|null};
export type Locker = {id:string; centerId:string; number:string; location:string; price:number; status:'AVAILABLE'|'OCCUPIED'|'MAINTENANCE'|'DISABLED'};
export type Payment = {id:string; memberId:string; centerId:string; amount:number; status:'PAID'|'FAILED'; createdAt:string; description:string; provider:'mock'; subscriptionId?:string; requestId:string};
export type Attendance = {id:string; memberId:string; centerId:string; productId:string; createdAt:string; success:boolean; reason:string};
export type State = {centers:Center[]; products:Product[]; members:Member[]; subscriptions:Subscription[]; lockers:Locker[]; payments:Payment[]; attendance:Attendance[]; priceHistory:{id:string;productId:string;oldPrice:number;newPrice:number;createdAt:string}[]; lockerHistory:{id:string;subscriptionId:string;from:string|null;to:string;createdAt:string}[]; paymentConfigs:{centerId:string;provider:'mock'|'toss';merchantLabel:string;enabled:boolean}[]; orders:{id:string;memberId:string;productId:string;quantity:number;unitPrice:number;createdAt:string}[]};
export const money=(n:number)=>new Intl.NumberFormat('ko-KR').format(n)+'원';
export const day=(d=new Date())=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(d);
export const uid=()=>crypto.randomUUID();
export function monthEnd(start:string){const d=new Date(start+'T00:00:00Z');const n=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,1));n.setUTCDate(Math.min(d.getUTCDate(),new Date(Date.UTC(n.getUTCFullYear(),n.getUTCMonth()+1,0)).getUTCDate()));return n.toISOString().slice(0,10)}
export function weekStart(){const d=new Date(day()+'T00:00:00Z');d.setUTCDate(d.getUTCDate()-(d.getUTCDay()+6)%7);return d.toISOString().slice(0,10)}
export function usable(s:Subscription){return ['ACTIVE','CANCEL_AT_PERIOD_END'].includes(s.status)&&s.start<=day()&&s.end>day()}
export function reserved(s:Subscription){return s.status!=='EXPIRED'&&s.end>day()}
export function normalize(state:State){for(const s of state.subscriptions){if(s.end<=day()&&s.status!=='EXPIRED'){s.status='EXPIRED';const l=state.lockers.find(l=>l.id===s.lockerId);if(l)l.status='AVAILABLE';}}return state}
export const labels:Record<string,string>={ACTIVE:'정상 이용 중',CANCEL_AT_PERIOD_END:'기간 종료 후 해지',EXPIRED:'기간 만료',PAYMENT_FAILED:'결제 실패',SUSPENDED:'이용 정지',AVAILABLE:'사용 가능',OCCUPIED:'사용 중',MAINTENANCE:'점검 중',DISABLED:'사용 중단',PAID:'결제 완료',FAILED:'결제 실패'};

export const cycleLabel=(p:Product)=>`${p.intervalCount??1}${p.intervalUnit==="week"?"주":"개월"}`;
