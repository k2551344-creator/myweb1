export const uid=()=>crypto.randomUUID();
export const today=(date=new Date())=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(date);
export function phone(value){let p=String(value||'').replace(/\D/g,'');if(p.startsWith('82'))p='0'+p.slice(2);if(!/^01[016789]\d{7,8}$/.test(p))throw Error('휴대폰 번호를 확인해 주세요.');return p;}
export function addPeriod(date,period){const d=new Date(date+'T12:00:00Z');if(period==='week'||period==='fortnight')d.setUTCDate(d.getUTCDate()+(period==='week'?7:14));else {const day=d.getUTCDate();d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+1);d.setUTCDate(Math.min(day,new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate()));}return d.toISOString().slice(0,10);}
export function weekStart(date){const d=new Date(date+'T12:00:00Z');d.setUTCDate(d.getUTCDate()-(d.getUTCDay()+6)%7);return d.toISOString().slice(0,10);}
export const seed=()=>({centers:[{id:'cherry',name:'CHERRY BOXING',owner:'',address:'',phone:'',privacy:'',terms:'',clientKey:''}],branches:[{id:'branch-1',centerId:'cherry',name:'서울대입구점',address:'지점 주소를 입력해 주세요',fixedQr:true,personalQr:true,qrSecret:uid()}],products:[{id:'plan-2',centerId:'cherry',branchId:'branch-1',name:'주 2회 복싱',kind:'membership',price:99000,period:'month',weekly:2,description:'나만의 속도로, 꾸준하게. 주 2회 운동을 시작하세요.',terms:'',active:true},{id:'plan-3',centerId:'cherry',branchId:'branch-1',name:'주 3회 복싱',kind:'membership',price:129000,period:'month',weekly:3,description:'일상에 운동의 리듬을 더하세요. 주 3회 자유롭게 이용합니다.',terms:'',active:true},{id:'plan-free',centerId:'cherry',branchId:'branch-1',name:'자유 이용권',kind:'membership',price:159000,period:'month',weekly:0,description:'운동하고 싶은 날 언제든. 횟수 제한 없이 이용하세요.',terms:'',active:true}],members:[],memberships:[],attendance:[],lockers:Array.from({length:12},(_,i)=>({id:'locker-'+(i+1),centerId:'cherry',branchId:'branch-1',name:String(i+1).padStart(2,'0'),location:'입구 왼쪽',price:10000,active:true,memberId:null,end:null})),orders:[],audit:[]});
export function isAdmin(user,centerId){return user?.role==='admin'&&(!user.centerIds?.length||user.centerIds.includes(centerId));}
export function visible(state,user){const s=structuredClone(state);s.branches=s.branches.map(({qrSecret,...b})=>isAdmin(user,b.centerId)?{...b,qrSecret}:b);s.members=s.members.filter(m=>m.id===user?.id||isAdmin(user,m.centerId)).map(({passwordHash,...m})=>m);for(const key of ['memberships','attendance','orders'])s[key]=s[key].filter(r=>r.memberId===user?.id||isAdmin(user,r.centerId));s.audit=s.audit.filter(r=>isAdmin(user,r.centerId));s.lockers=s.lockers.map(l=>l.memberId&&l.memberId!==user?.id&&!isAdmin(user,l.centerId)?{...l,memberId:'occupied'}:l);return s;}
const need=(condition,message)=>{if(!condition)throw Error(message);};
export function reduce(state,user,action,p={},date=today()){
 const s=structuredClone(state);let result={};const log=(centerId,detail)=>s.audit.unshift({id:uid(),centerId,actor:user?.id,detail,at:new Date().toISOString()});
 if(action==='save'){
  need(['centers','branches','products','lockers'].includes(p.table),'수정할 수 없는 항목입니다.');let old=s[p.table].find(x=>x.id===p.record.id);const centerId=p.table==='centers'?p.record.id:p.record.centerId;
  need(isAdmin(user,centerId)&&(!old||isAdmin(user,p.table==='centers'?old.id:old.centerId)),'관리자 권한이 필요합니다.');
  const r={...p.record,id:old?.id||p.record.id||uid()};need(String(r.name||'').trim(),'이름을 입력해 주세요.');
  if(p.table!=='centers')need(s.centers.some(c=>c.id===r.centerId),'센터를 선택해 주세요.');
  if(['products','lockers'].includes(p.table)){need(Number.isInteger(r.price)&&r.price>=100,'가격은 100원 이상의 정수여야 합니다.');need(s.branches.some(b=>b.id===r.branchId&&b.centerId===r.centerId),'지점을 확인해 주세요.');}
  if(p.table==='products'){need(['membership','goods'].includes(r.kind),'상품 종류 오류');need(['once','week','fortnight','month'].includes(r.period),'주기 오류');need(Number.isInteger(r.weekly)&&r.weekly>=0,'이용 횟수를 확인해 주세요.');if(r.kind==='goods')r.period='once';}
  if(p.table==='branches')r.qrSecret=old?.qrSecret||uid();
  if(p.table==='lockers'){r.memberId=old?.memberId||null;r.end=old?.end||null;}
  if(old)Object.assign(old,r);else s[p.table].push(r);log(centerId,`${p.table}: ${r.name} 저장`);
 }else if(action==='grant'){
  const product=s.products.find(x=>x.id===p.productId);need(product&&isAdmin(user,product.centerId),'상품 또는 권한을 확인해 주세요.');need(product.kind==='membership','이용권을 선택해 주세요.');need(s.members.some(m=>m.id===p.memberId&&(m.centerId===product.centerId||!user.centerIds?.length)),'회원을 찾을 수 없습니다.');need(/^\d{4}-\d{2}-\d{2}$/.test(p.start)&&p.end>p.start,'이용기간을 확인해 주세요.');need(p.reason?.trim(),'지급 사유를 입력해 주세요.');
  s.memberships.push({id:uid(),memberId:p.memberId,centerId:product.centerId,branchId:product.branchId,productId:product.id,name:product.name,weekly:product.weekly,start:p.start,end:p.end,renew:false,status:'active',period:product.period,price:product.price});log(product.centerId,`이용권 수동 지급: ${p.reason}`);
 }else if(action==='checkin'){
  need(user,'로그인해 주세요.');const branch=s.branches.find(b=>b.id===p.branchId);need(branch,'지점을 찾을 수 없습니다.');let memberId=user.id;
  if(p.method==='personal'){need(isAdmin(user,branch.centerId),'태블릿 관리자 로그인이 필요합니다.');need(branch.personalQr,'개인 QR 출석이 꺼져 있습니다.');need(p.verifiedMemberId,'유효한 개인 QR을 스캔해 주세요.');memberId=p.verifiedMemberId;}
  else {need(branch.fixedQr,'고정 QR 출석이 꺼져 있습니다.');need(p.secret===branch.qrSecret,'올바른 지점 QR을 스캔해 주세요.');}
  const passes=s.memberships.filter(m=>m.memberId===memberId&&m.branchId===branch.id&&m.status==='active'&&m.start<=date&&m.end>date);
  need(passes.length,'이 지점에서 사용할 수 있는 이용권이 없습니다.');
  if(s.attendance.some(a=>a.memberId===memberId&&a.date===date)){result={message:'오늘 출석이 이미 처리되었습니다.',duplicate:true};}
  else {const pass=passes.find(m=>!m.weekly||s.attendance.filter(a=>a.membershipId===m.id&&a.date>=weekStart(date)&&a.date<=date).length<m.weekly);need(pass,'이번 주 이용 횟수를 모두 사용했습니다.');s.attendance.unshift({id:uid(),memberId,centerId:branch.centerId,branchId:branch.id,membershipId:pass.id,date,method:p.method,at:new Date().toISOString()});result={message:'출석 완료! 오늘도 좋은 운동 하세요.'};}
 }else if(action==='cancel'){
  const m=s.memberships.find(m=>m.id===p.id);need(m&&(m.memberId===user?.id||isAdmin(user,m.centerId)),'이용권을 찾을 수 없습니다.');m.renew=false;log(m.centerId,'다음 자동결제 해제');
 }else if(action==='moveLocker'){
  const from=s.lockers.find(l=>l.id===p.from),to=s.lockers.find(l=>l.id===p.to);need(from&&to&&from.branchId===to.branchId&&isAdmin(user,from.centerId),'같은 지점의 락카를 선택해 주세요.');need(from.memberId&&(!to.memberId||to.end<=date),'이동할 락카가 사용 중입니다.');to.memberId=from.memberId;to.end=from.end;from.memberId=null;from.end=null;log(from.centerId,'락카 위치 변경');
 }else throw Error('지원하지 않는 작업입니다.');return {state:s,result};
}
export function fulfill(state,orderId,paymentKey,date=today()){
 const s=structuredClone(state),o=s.orders.find(o=>o.id===orderId);need(o,'주문을 찾을 수 없습니다.');if(o.status==='paid')return s;o.status='paid';o.paymentKey=paymentKey;o.paidAt=new Date().toISOString();
 if(o.kind==='membership'){
  const current=o.membershipId&&s.memberships.find(m=>m.id===o.membershipId);if(current){current.end=addPeriod(current.end,current.period);current.status='active';}
  else {const id=uid();s.memberships.push({id,memberId:o.memberId,centerId:o.centerId,branchId:o.branchId,productId:o.productId,name:o.name,weekly:o.weekly,start:date,end:addPeriod(date,o.period),period:o.period,price:o.amount,renew:o.period!=='once',status:'active',billingRef:o.billingRef||null});o.membershipId=id;}
 }else if(o.kind==='locker'){const l=s.lockers.find(l=>l.id===o.productId);need(l,'락카 없음');need(!l.memberId||l.end<=date||l.memberId===o.memberId,'이미 사용 중인 락카입니다.');l.memberId=o.memberId;l.end=addPeriod(l.end>date?l.end:date,'month');}
 return s;
}
export function makeOrder(s,user,p,date=today()){
 need(user,'로그인해 주세요.');const product=(p.kind==='locker'?s.lockers:s.products).find(x=>x.id===p.productId&&x.active);need(product,'판매 중인 상품이 없습니다.');const center=s.centers.find(c=>c.id===product.centerId);need(p.agree===true,'구매 약관에 동의해 주세요.');
 if(p.kind==='locker'){need(!product.memberId||product.end<=date||product.memberId===user.id,'사용 중인 락카입니다.');need(!s.orders.some(o=>o.productId===product.id&&(o.status==='processing'||(o.status==='pending'&&new Date(o.createdAt).getTime()>Date.now()-15*60000))),'결제가 진행 중인 락카입니다. 잠시 후 다시 시도해 주세요.');}
 return {id:uid(),memberId:user.id,centerId:product.centerId,branchId:product.branchId,productId:product.id,name:product.name,kind:p.kind==='locker'?'locker':product.kind,amount:product.price,period:p.kind==='locker'?'once':product.period,weekly:product.weekly||0,status:'pending',createdAt:new Date().toISOString(),agreement:{terms:product.terms||'',service:center.terms||'',privacy:center.privacy||'',at:new Date().toISOString()}};
}
