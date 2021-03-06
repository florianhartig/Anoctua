# calculate parameter estimates 
getEstimate <- function(summaryChoice, proportionFiltered = 1/1000, parallel = FALSE, regr.adj = TRUE, comp.MAP = TRUE, CI.range = c(0.025,0.975)){
  # start timing 
  ptm <- proc.time()
  
  
  # load rcpp function to calculate distance between observed and simulated data
  Rcpp::sourceCpp("../code/c++/distanceObservedSimulated.cpp")
  
  numberParametersFiltered = ceiling(nrow(summaryChoice$parameters) * proportionFiltered)
  
  # upper and lower bounds for truncated multivariate normal distribution
  lbounds <- apply(summaryChoice$parameters[,summaryChoice$summarySelection$targetParameters],
                   2, min)
  ubounds <- apply(summaryChoice$parameters[,summaryChoice$summarySelection$targetParameters],
                   2, max)
  
  distances <- filtered <- pQuantiles <- pMedian <- pMEst <- vector("list", length(summaryChoice$summarySelection$observed))
  if(regr.adj) pMedian.regrAdj <- pQuantiles.regrAdj <- filtered.regrAdj <- vector("list", length(summaryChoice$summarySelection$observed))
  for(i in seq_along(summaryChoice$summarySelection$observed)){
    
    # standardise by range
    reference <- unlist(diff(apply(summaryChoice$summarySelection$simulation[[i]], 2, range)))

    distances[[i]] <- dObsSim(simulated = as.matrix(summaryChoice$summarySelection$simulation[[i]]),
                              observed = unlist(summaryChoice$summarySelection$observed[[i]]),
                              reference = reference)
    
    # accepted indices
    filtered_indices <- sort(distances[[i]], method = "quick", 
                            index.return = TRUE)$ix[1:numberParametersFiltered]
    
    # accepted paramter samples
    filtered[[i]] <- summaryChoice$parameters[filtered_indices, 
                                              summaryChoice$summarySelection$targetParameters]
    
    if(regr.adj){
      # copy filtered
      filtered.regrAdj[[i]] <- filtered[[i]]
      # S_sim of accepted sample
      filtered_ss <- summaryChoice$summarySelection$simulation[[i]][filtered_indices,]
      for(c in seq(NCOL(filtered_ss))) # center around S_obs
        filtered_ss[,c] <- filtered_ss[,c] - summaryChoice$summarySelection$observed[[i]][,c]
      # post-sampling regression adjustment, multivariate linear model
      psr.fm <- lm(as.formula(paste("filtered.regrAdj[[i]]~",paste(colnames(filtered_ss), collapse = "+"))), 
                   data = as.data.frame(filtered_ss))$coefficients[-1,] # remove intercept
      # correct for epsilon != 0
      filtered.regrAdj[[i]] <- sapply(seq(NCOL(filtered_ss)), 
                              function(x) filtered.regrAdj[[i]][,x] - rowSums(t(psr.fm[,x] * t(filtered_ss))))
      # restrict corrections to prior bounds
      filtered.regrAdj[[i]] <- sapply(seq(NCOL(filtered_ss)),
                              function(x) ifelse(filtered.regrAdj[[i]][,x] < lbounds[x], lbounds[x], 
                                                 ifelse(filtered.regrAdj[[i]][,x] > ubounds[x], ubounds[x], 
                                                        filtered.regrAdj[[i]][,x])))
      colnames(filtered.regrAdj[[i]]) <- colnames(summaryChoice$parameters)[summaryChoice$summarySelection$targetParameters]
      
      pMedian.regrAdj[[i]] <- apply(filtered.regrAdj[[i]], 2, median)
      pQuantiles.regrAdj[[i]] <- apply(filtered.regrAdj[[i]], 2, quantile, probs = CI.range)
    }

    # posterior statistics
    pMedian[[i]] <- apply(filtered[[i]], 2, median)
    pQuantiles[[i]] <- apply(filtered[[i]], 2, quantile, probs = CI.range)
    pMEst[[i]] <- unlist(summaryChoice$summarySelection$observed[[i]])
  }
  
  if(comp.MAP){
    if(!parallel){
      library(tmvtnorm)
      pMAP <- vector("list", length(summaryChoice$summarySelection$observed))
      if(regr.adj) pMAP.regrAdj <- vector("list", length(summaryChoice$summarySelection$observed))
      
      # progress bar
      pb <- txtProgressBar(min = 1, max = length(summaryChoice$summarySelection$observed), style = 3)
      
      for(i in seq_along(summaryChoice$summarySelection$observed)){
        pMAP[[i]] <- mle.tmvnorm(filtered[[i]], method = "L-BFGS-B", 
                                 lower.bounds = lbounds, 
                                 upper.bounds = ubounds)@coef[1:NCOL(filtered[[i]])]
        pMAP[[i]] <- ifelse(pMAP[[i]] < lbounds, lbounds,
                            ifelse(pMAP[[i]] > ubounds, ubounds,
                                   pMAP[[i]]))
        names(pMAP[[i]]) <- colnames(sumOut$parameters)[sumOut$summarySelection$targetParameters]
        
        if(regr.adj){
          pMAP.regrAdj[[i]] <- mle.tmvnorm(filtered.regrAdj[[i]], method = "L-BFGS-B", 
                                   lower.bounds = lbounds, 
                                   upper.bounds = ubounds)@coef[1:NCOL(filtered.regrAdj[[i]])]
          pMAP.regrAdj[[i]] <- ifelse(pMAP.regrAdj[[i]] < lbounds, lbounds,
                              ifelse(pMAP.regrAdj[[i]] > ubounds, ubounds,
                                     pMAP.regrAdj[[i]]))
          names(pMAP.regrAdj[[i]]) <- colnames(sumOut$parameters)[sumOut$summarySelection$targetParameters]
        }
        
        # progress bar
        setTxtProgressBar(pb, i)
      }
      close(pb)
    }else{
      # parallel execution
      library(foreach)
      # library(doParallel)
      library(doSNOW)
      
      if(parallel == T | parallel == "auto"){
        cores <- parallel::detectCores() - 1
        message("parallel, set cores automatically to ", cores)
      }else if (is.numeric(parallel)){
        cores <- parallel
        message("parallel, set number of cores manually to ", cores)
      }else stop("wrong argument to parallel")
      
      
      cl <- parallel::makeCluster(cores)
      doSNOW::registerDoSNOW(cl)
      
      # set up progress bar
      pb <- txtProgressBar(min = 1, max = length(summaryChoice$summarySelection$observed), style = 3)
      progress <- function(n) setTxtProgressBar(pb, n)
      opts <- list(progress = progress)
      
      pMAP <- foreach::foreach(i = seq_along(summaryChoice$summarySelection$observed), 
                               .options.snow=opts, .packages = "tmvtnorm") %dopar% {
                                 maps <- mle.tmvnorm(filtered[[i]], method = "L-BFGS-B",
                                                     lower.bounds = lbounds, 
                                                     upper.bounds = ubounds)@coef[1:NCOL(filtered[[i]])]
                                 maps <- ifelse(maps < lbounds, lbounds,
                                                ifelse(maps > ubounds, ubounds,
                                                       maps))
                                 names(maps) <- colnames(sumOut$parameters)[sumOut$summarySelection$targetParameters]
                                 maps
                               }
      
      if(regr.adj){
        pMAP.regrAdj <- foreach::foreach(i = seq_along(summaryChoice$summarySelection$observed), 
                                 .options.snow=opts, .packages = "tmvtnorm") %dopar% {
                                   maps <- mle.tmvnorm(filtered.regrAdj[[i]], method = "L-BFGS-B",
                                                       lower.bounds = lbounds, 
                                                       upper.bounds = ubounds)@coef[1:NCOL(filtered.regrAdj[[i]])]
                                   maps <- ifelse(maps < lbounds, lbounds,
                                                  ifelse(maps > ubounds, ubounds,
                                                         maps))
                                   names(maps) <- colnames(sumOut$parameters)[sumOut$summarySelection$targetParameters]
                                   maps
                                 }
      }
      # free memory from workers
      close(pb)
      stopCluster(cl)
    }
  }  
  
  
  
  res = NULL
  res$parameters = filtered
  res$median = pMedian
  res$quantiles = pQuantiles
  if(comp.MAP) res$MAP = pMAP
  if(regr.adj){
    res$parameters.regrAdj = filtered.regrAdj
    res$median.regrAdj = pMedian.regrAdj
    res$quantiles.regrAdj = pQuantiles.regrAdj
    if(comp.MAP) res$MAP.regrAdj = pMAP.regrAdj
  } 
  res$model.estimate = pMEst
  res$targetParameters = summaryChoice$summarySelection$targetParameters
  res$proportion = proportionFiltered
  
  # stop timing
  print(proc.time() - ptm)
  
  return(res)
}
