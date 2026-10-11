import {State,uid} from '../../lib/model';
export function charge(state:State,centerId:string,memberId:string,amount:number,description:string,requestId:string,fail=false,subscriptionId?:string){
 const config=state.paymentConfigs.find(c=>c.centerId===centerId);
 if(!config?.enabled)throw Error('이 센터는 현재 결제를 받을 수 없습니다.');
 if(config.provider!=='mock')throw Error('Toss 결제는 아직 연결되지 않았습니다. 테스트 결제를 선택해 주세요.');
 const payment={id:uid(),centerId,memberId,amount,description,requestId,subscriptionId,status:fail?'FAILED' as const:'PAID' as const,provider:'mock' as const,createdAt:new Date().toISOString()};
 state.payments.unshift(payment);return payment;
}
