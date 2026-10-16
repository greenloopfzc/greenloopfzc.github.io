/* Account display choices, shared by the wall, history and summary views. ES5. */
(function(root){
 "use strict";
 var full={tv_only:false,show_parts:true,show_original:true,show_copy:true,show_payable:true,revision:"0"};
 function settings(){return (root.GREENLOOP_TV_API && root.GREENLOOP_TV_API.display)||full;}
 function payable(){return settings().show_payable!==false && prices();}
 function prices(){var d=settings();return d.show_original||d.show_copy;}
 function dual(original,copy){var d=settings();return (d.show_original ? '<span class="damage-dual-line">Original: '+original+'</span>' : '')+(d.show_copy ? '<span class="damage-dual-line">Copy: '+copy+'</span>' : '');}
 function table(html,hidden){
  if(!hidden.length)return html;
  var holder=document.createElement('div');holder.innerHTML=html;
  var rows=holder.querySelectorAll('tr'),cols=holder.querySelectorAll('col'),i,j,cells;
  for(i=0;i<rows.length;i++){cells=rows[i].children;if(cells.length===1 && cells[0].colSpan>1){cells[0].colSpan=Math.max(1,cells[0].colSpan-hidden.length);continue;}for(j=cells.length-1;j>=0;j--)if(hidden.indexOf(j)>=0)rows[i].removeChild(cells[j]);}
  for(i=cols.length-1;i>=0;i--)if(hidden.indexOf(i)>=0)cols[i].parentNode.removeChild(cols[i]);
  return holder.innerHTML;
 }
 function apply(){var d=settings(),parts=['today','month','all'],i;document.body.setAttribute('data-tv-parts',String(d.show_parts));document.body.setAttribute('data-tv-prices',String(prices()));
  for(i=0;i<parts.length;i++)document.getElementById('damage-summary-'+parts[i]).style.display=d.show_parts ? '' : 'none';
  document.getElementById('damage-summary-value').style.display=prices() ? '' : 'none';document.getElementById('damage-summary-payable').style.display=payable() ? '' : 'none';
  var visible=(d.show_parts ? 3 : 0)+(prices() ? 1 : 0)+(payable() ? 1 : 0),cards=document.querySelectorAll('[data-damage-summary]');
  var shown=0;for(i=0;i<cards.length;i++){if(cards[i].style.display!=='none')shown++;cards[i].style.width=(window.innerWidth<=650 ? (visible%2===1 && shown===visible ? 100 : 50) : 100/Math.max(1,visible))+'%';}
 }
 root.GREENLOOP_DAMAGE_DISPLAY={get:settings,prices:prices,payable:payable,dual:dual,table:table,apply:apply,hasDamage:function(e){return e.has_damage===true || e.total_damage>0;}};
}(window));
