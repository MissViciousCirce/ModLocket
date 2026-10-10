using System;
using System.Collections.Generic;
using System.Text;
namespace ModLocket {
// Minimal JSON syntax tree retaining source spans. Unedited fields are never
// reserialized, so account identifiers and large integers retain exact bytes.
public static class JsonPatch {
 public static void Commit(string pending,string library){System.IO.File.Replace(pending,library,null);}
 class Node { public int Start,End; public string Text; public Dictionary<string,Node> Props; public List<Node> Items; }
 class Parser {
  string s; int i;
  public Parser(string value){s=value;}
  void White(){while(i<s.Length && char.IsWhiteSpace(s[i]))i++;}
  string Str(){
   if(s[i++]!='"')throw new FormatException("Expected JSON string.");
   var b=new StringBuilder();
   while(i<s.Length){char c=s[i++];if(c=='"')return b.ToString();
    if(c=='\\'){if(i>=s.Length)break;c=s[i++];
     switch(c){case '"':case '\\':case '/':b.Append(c);break;
      case 'b':b.Append('\b');break;case 'f':b.Append('\f');break;case 'n':b.Append('\n');break;case 'r':b.Append('\r');break;case 't':b.Append('\t');break;
      case 'u':if(i+4>s.Length)throw new FormatException();b.Append((char)Convert.ToInt32(s.Substring(i,4),16));i+=4;break;
      default:throw new FormatException();}
    }else{if(c<32)throw new FormatException();b.Append(c);}
   }throw new FormatException("Unterminated JSON string.");
  }
  Node Value(int depth){
   if(depth>100)throw new FormatException("JSON nesting exceeds limit.");White();if(i>=s.Length)throw new FormatException();
   var n=new Node{Start=i};char c=s[i];
   if(c=='{'){
    i++;n.Props=new Dictionary<string,Node>(StringComparer.Ordinal);White();
    if(i<s.Length && s[i]=='}')i++;
    else while(true){White();string k=Str();White();if(s[i++]!=':')throw new FormatException();if(n.Props.ContainsKey(k))throw new FormatException("Duplicate JSON property.");n.Props.Add(k,Value(depth+1));White();c=s[i++];if(c=='}')break;if(c!=',')throw new FormatException();}
   }else if(c=='['){
    i++;n.Items=new List<Node>();White();if(i<s.Length && s[i]==']')i++;
    else while(true){n.Items.Add(Value(depth+1));White();c=s[i++];if(c==']')break;if(c!=',')throw new FormatException();}
   }else if(c=='"'){n.Text=Str();}
   else{while(i<s.Length && !char.IsWhiteSpace(s[i]) && s[i]!=',' && s[i]!=']' && s[i]!='}')i++;n.Text=s.Substring(n.Start,i-n.Start);if(!System.Text.RegularExpressions.Regex.IsMatch(n.Text,@"^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)$"))throw new FormatException();}
   n.End=i;return n;
  }
  public Node Parse(){var n=Value(0);White();if(i!=s.Length)throw new FormatException();return n;}
 }
 static Node Prop(Node n,string k){Node v;if(n.Props==null || !n.Props.TryGetValue(k,out v))throw new FormatException("Missing metadata field: "+k);return v;}
 static Node Records(Node root,out string profile){
  if(root.Items!=null){profile="root";return root;}
  if(root.Props==null)throw new FormatException("Unsupported mod library.");
  bool asa=root.Props.ContainsKey("installedMods"),flat=root.Props.ContainsKey("mods");
  if(asa==flat)throw new FormatException("Ambiguous mod library.");
  profile=asa?"installedMods":"mods";var records=Prop(root,profile);
  if(records.Items==null)throw new FormatException("Mod list is not an array.");return records;
 }
 static Dictionary<string,Node> ById(Node records,string profile){
  var result=new Dictionary<string,Node>(StringComparer.Ordinal);
  foreach(var r in records.Items){
   string id=null;
   if(profile=="installedMods")id=Prop(Prop(r,"details"),"id").Text;
   else{foreach(string k in new[]{"modId","projectId","id"})if(r.Props!=null && r.Props.ContainsKey(k)){if(id!=null)throw new FormatException("Ambiguous project ID.");id=r.Props[k].Text;}}
   if(id==null || !System.Text.RegularExpressions.Regex.IsMatch(id,@"^[1-9][0-9]{4,8}$") || result.ContainsKey(id))throw new FormatException("Invalid or duplicate project ID.");
   result.Add(id,r);
  }return result;
 }
 // Insert only explicitly reviewed missing records. All existing JSON bytes,
 // including large integers, preferences and other accounts, remain unchanged.
 public static string RestoreRecords(string current,string saved,string[] ids){
  string cp,sp;var cr=Records(new Parser(current).Parse(),out cp);var sr=Records(new Parser(saved).Parse(),out sp);
  if(cp!=sp)throw new FormatException("Backup and current library formats differ.");
  var live=ById(cr,cp);var backup=ById(sr,sp);var selected=new HashSet<string>(StringComparer.Ordinal);var added=new List<string>();
  foreach(string id in ids){
   if(!selected.Add(id) || live.ContainsKey(id) || !backup.ContainsKey(id))throw new FormatException("Restore selection is not a missing backed-up project.");
   var r=backup[id];added.Add(saved.Substring(r.Start,r.End-r.Start));
  }
  if(added.Count==0)return current;
  return current.Insert(cr.End-1,(cr.Items.Count>0?",":"")+String.Join(",",added.ToArray()));
 }
 public static string Update(string json,string modId,string fileJson,string pathJson,string utcJson){
  var root=new Parser(json).Parse();var records=Prop(root,"installedMods");if(records.Items==null)throw new FormatException();
  Node target=null;foreach(var r in records.Items){if(Prop(Prop(r,"details"),"id").Text==modId){if(target!=null)throw new FormatException("Duplicate project.");target=r;}}
  if(target==null)throw new FormatException("Project absent from library.");new Parser(fileJson).Parse();new Parser(pathJson).Parse();new Parser(utcJson).Parse();
  var edits=new List<KeyValuePair<Node,string>>();
  edits.Add(new KeyValuePair<Node,string>(Prop(target,"installedFile"),fileJson));
  edits.Add(new KeyValuePair<Node,string>(Prop(target,"latestUpdatedFile"),fileJson));
  edits.Add(new KeyValuePair<Node,string>(Prop(target,"pathOnDisk"),pathJson));
  edits.Add(new KeyValuePair<Node,string>(Prop(target,"status"),"\"Normal\""));
  foreach(string k in new[]{"dateInstalled","dateUpdated"})if(target.Props.ContainsKey(k))edits.Add(new KeyValuePair<Node,string>(target.Props[k],utcJson));
  // Stale partial-download state is owned by ARK. Refuse to overwrite it.
  Node info;if(target.Props.TryGetValue("downloadInfo",out info) && info.Text!="null" && (info.Props==null || info.Props.Count!=0))throw new FormatException("ARK has download bookkeeping for this mod. Complete it in ARK first.");
  edits.Sort((a,b)=>b.Key.Start.CompareTo(a.Key.Start));var result=new StringBuilder(json);
  foreach(var e in edits){result.Remove(e.Key.Start,e.Key.End-e.Key.Start);result.Insert(e.Key.Start,e.Value);}new Parser(result.ToString()).Parse();return result.ToString();
 }
}
}
