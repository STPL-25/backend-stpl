
class ErrorHandling {
   
static throwErrorMsg=(res,error)=>{
  const errorMsg={
    error:error.message,
    message:"Internal Server Error",
    sucess:false
  }
    return res.status(500).json(errorMsg)

}

}


export default ErrorHandling;